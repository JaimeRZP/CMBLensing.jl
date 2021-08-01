
# Some initial support for Healpix fields. 
# The main functionality of broadcasting, indexing, and projection for
# a few field types is implemented, but not much beyond that. 


@init global hp = lazy_pyimport("healpy")

struct ProjHealpix <: Proj
    Nside :: Int
end
make_field_aliases("Healpix", ProjHealpix)
typealias_def(::Type{<:ProjHealpix}) = "ProjHealpix"


## constructing from arrays
# spin-0
function HealpixMap(I::A) where {T, A<:AbstractArray{T}}
    HealpixMap(I, ProjHealpix(hp.npix2nside(length(I))))
end
# spin-2
function HealpixField{B}(X::A, Y::A) where {T, A<:AbstractArray{T}, B<:Basis2Prod{<:Union{𝐐𝐔,𝐄𝐁},Map}}
    HealpixField{B}(cat(X, Y, dims=Val(2)), ProjHealpix(hp.npix2nside(length(X))))
end
# spin-(0,2)
function HealpixField{B}(I::A, X::A, Y::A) where {T, A<:AbstractArray{T}, B<:Basis3Prod{𝐈,<:Union{𝐐𝐔,𝐄𝐁},Map}}
    HealpixField{B}(cat(I, X, Y, dims=Val(2)), ProjHealpix(hp.npix2nside(length(I))))
end

### pretty printing
typealias_def(::Type{F}) where {B,M<:ProjHealpix,T,A,F<:HealpixField{B,M,T,A}} = "Healpix$(typealias(B)){$(typealias(A))}"
function Base.summary(io::IO, f::HealpixField)
    @unpack Nside = f
    print(io, "$(length(f))-element Nside=$Nside ")
    Base.showarg(io, f, true)
end

getproperty(f::HealpixField, ::Val{:proj}) = getfield(f,:metadata)
pol_slice(::HealpixField, i) = (:, i)


### broadcasting

function promote_metadata_strict(metadata₁::ProjHealpix, metadata₂::ProjHealpix)
    if metadata₁ === metadata₂
        metadata₁
    else
        error("Can't broadcast Healpix maps with two different Nsides ($metadata₁.Nside, $metadata₂.Nside).")
    end
end


### Projection

# adding more flat projections in the future should be as easy as
# defining pairs of functions like the above two for other cases


## ProjEquiRect
function θϕ_to_ij(proj::ProjEquiRect, θ, ϕ)
    @unpack Ny, Nx, θspan, ϕspan = proj
    i =        (θ - θspan[1])             / abs(-(θspan...)) * Ny
    j = rem2pi((ϕ - ϕspan[1]), RoundDown) / abs(-(ϕspan...)) * Nx
    (i, j)
end

function ij_to_θϕ(proj::ProjEquiRect, i, j)
    @unpack Ny, Nx, θspan, ϕspan = proj
    θ = abs(-(θspan...)) / Ny * i + θspan[1]
    ϕ = abs(-(ϕspan...)) / Nx * j + ϕspan[1]
    (θ, ϕ)
end


## ProjLambert
# 
# Notes:
# * choices of negative signs are such that the default projection is
#   centered on the center of a healpy.mollview plot and oriented the
#   same way
# * we have to define these at the "broadcasted" level so we can do
#   just a single call to Rotator(), otherwise it'd be really slow

function broadcasted(::typeof(ij_to_θϕ), proj::ProjLambert, is, js)
    @unpack Δx, Ny, Nx, rotator = proj
    θϕs = broadcast(is, js) do i, j
        x = Δx * (j - Nx÷2 - 0.5)
        y = Δx * (i - Ny÷2 - 0.5)
        r = sqrt(x^2 + y^2)
        θ = 2*acos(r/2)
        ϕ = atan(-x, -y)
        θ, ϕ
    end
    R = hp.Rotator(rotator)
    θϕs = reshape(R.get_inverse()(first.(θϕs)[:], last.(θϕs)[:]), 2, size(θϕs)...)
    tuple.(θϕs[1,:,:], θϕs[2,:,:])
end

function broadcasted(::typeof(θϕ_to_ij), proj::ProjLambert, θs, ϕs)
    @unpack Δx, Ny, Nx, rotator = proj
    R = hp.Rotator(rotator)
    (θs, ϕs) = eachrow(R(θs, ϕs))
    broadcast(θs, ϕs) do θ, ϕ
        r = 2cos(θ/2)
        x = -r*sin(ϕ)
        y = -r*cos(ϕ)
        i = y / Δx + Ny÷2 + 0.5
        j = x / Δx + Nx÷2 + 0.5
        (i, j)
    end
end



## Healpix => Cartesian

"""
    project(healpix_map::HealpixField => cart_proj::CartesianProj)

Project `healpix_map` to a cartisian projection specified by
`cart_proj`. E.g.:

    healpix_map = HealpixMap(rand(12*2048^2))
    flat_proj = ProjLambert(Ny=128, Nx=128, θpix=3, T=Float32)
    f = project(healpix_map => flat_proj; rotator=pyimport("healpy").Rotator((0,28,23)))

The use of `=>` is to help remember in which order the arguments are
specified. If `healpix_map` is a `HealpixQU`, Q/U polarization angles
are rotated to be aligned with the local coordinates (sometimes called
"polarization flattening").
"""
function project((hpx_map, cart_proj)::Pair{<:HealpixMap,<:CartesianProj})
    @unpack Ny, Nx = cart_proj
    _project(ij_to_θϕ.(cart_proj, 1:Ny, (1:Nx)'), hpx_map => cart_proj)
end

function project((hpx_map, cart_proj)::Pair{<:HealpixQUMap,<:ProjLambert{T}}) where {T}
    @unpack Ny, Nx, rotator = cart_proj
    θϕs = ij_to_θϕ.(cart_proj, 1:Ny, (1:Nx)')
    Q = _project(θϕs, hpx_map.Q => cart_proj)
    U = _project(θϕs, hpx_map.U => cart_proj)
    ψpol = reshape((hp.Rotator((0,-90,0)) * hp.Rotator(rotator)).angle_ref(first.(θϕs)[:], last.(θϕs)[:]), Ny, Nx)
    QU_flat = @. (Q.arr + im * U.arr) * exp(im * 2 * ψpol)
    FlatQUMap(real.(QU_flat), imag.(QU_flat), cart_proj)
end

function _project(θϕs, (hpx_map, cart_proj)::Pair{<:HealpixMap,<:CartesianProj})
    @unpack Ny, Nx = cart_proj
    BaseMap(reshape(hp.get_interp_val(collect(hpx_map), first.(θϕs)[:], last.(θϕs)[:]), Ny, Nx), cart_proj)
end


## Cartesian => Healpix

"""
    project(flat_map::FlatField => healpix_proj::ProjHealpix; [rotator])

Reproject a `flat_map` back onto the sphere in a Healpix projection
specified by `healpix_proj`. E.g.

    flat_map = FlatMap(rand(128,128))
    f = project(flat_map => ProjHealpix(2048); rotator=pyimport("healpy").Rotator((0,28,23)))

The use of `=>` is to help remember in which order the arguments are
specified. Optional keyword argument `rotator` is a `healpy.Rotator`
object specifying a rotation which rotates the north pole to the
center of the desired field. 
"""
function project((cart_map, hpx_proj)::Pair{<:CartesianS0, <:ProjHealpix})
    @unpack Nside = hpx_proj
    (θs, ϕs) = hp.pix2ang(Nside, 0:(12*Nside^2-1))
    ijs = θϕ_to_ij.(cart_map.proj, θs, ϕs)
    is, js = first.(ijs), last.(ijs)
    HealpixMap(@ondemand(Images.bilinear_interpolation).(Ref(cpu(Map(cart_map).Ix)), is, js), hpx_proj)
end