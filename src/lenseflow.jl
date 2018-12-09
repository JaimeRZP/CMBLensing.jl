
export LenseFlow, CachedLenseFlow

abstract type ODESolver end

abstract type LenseFlowOp{I<:ODESolver,t₀,t₁} <: LenseOp end

struct LenseFlow{I<:ODESolver,t₀,t₁,F<:Field} <: LenseFlowOp{I,t₀,t₁}
    ϕ::F
    ∇ϕ::SVector{2,F}
    Hϕ::SMatrix{2,2,F,4}
end

# constructors
LenseFlow{I}(ϕ::Field{<:Any,<:S0}) where {I<:ODESolver} = LenseFlow{I,0,1}(ϕ)
LenseFlow{n}(ϕ::Field{<:Any,<:S0}) where {n} = LenseFlow{jrk4{n},0,1}(ϕ)
LenseFlow{I,t₀,t₁}(ϕ::Field{<:Any,<:S0}) where {I,t₀,t₁} = LenseFlow{I,t₀,t₁}(Map(ϕ), gradhess(ϕ)...)
LenseFlow{I,t₀,t₁}(ϕ::F,∇ϕ,Hϕ) where {I,t₀,t₁,F} = LenseFlow{I,float(t₀),float(t₁),F}(ϕ,∇ϕ,Hϕ)
LenseFlow(args...) = LenseFlow{jrk4{7}}(args...)

# only one single ODE solver implemented for now, a simple custom RK4
abstract type jrk4{nsteps} <: ODESolver  end
jrk4{N}(F!,y₀,t₀,t₁) where {N} = jrk4(F!,y₀,t₀,t₁,N)

# todo, remove this `→` crap, maybe
@∷ _getindex(L::LenseFlow{I,∷,∷,F}, ::→{t₀,t₁}) where {I,t₀,t₁,F} = LenseFlow{I,t₀,t₁,F}(L.ϕ,L.∇ϕ,L.Hϕ)

# Define integrations for L*f, L'*f, L\f, and L'\f
*(L::        LenseFlowOp{I,t₀,t₁},  f::Field) where {I,t₀,t₁} = I((v,t,f)->velocity!( v,L, f,t), Ł(f), t₀, t₁)
*(L::AdjOp{<:LenseFlowOp{I,t₀,t₁}}, f::Field) where {I,t₀,t₁} = I((v,t,f)->velocityᴴ!(v,L',f,t), Ð(f), t₁, t₀)
\(L::        LenseFlowOp{I,t₀,t₁},  f::Field) where {I,t₀,t₁} = I((v,t,f)->velocity!( v,L, f,t), Ł(f), t₁, t₀)
\(L::AdjOp{<:LenseFlowOp{I,t₀,t₁}}, f::Field) where {I,t₀,t₁} = I((v,t,f)->velocityᴴ!(v,L',f,t), Ð(f), t₀, t₁)
# Define integrations for Jacobian
*(J::δfϕₛ_δfϕₜ{s,t,<:LenseFlowOp{I}}, (δf,δϕ)::FΦTuple) where {s,t,I} = 
    (gh = Ł.(gradhess(δϕ)); FieldTuple(I((v,t,y)->δvelocity!(v,J.L,y,δϕ,t,gh...),Ł(FieldTuple(J.fₜ,δf)),t,s)[2], δϕ))
*(J::AdjOp{<:δfϕₛ_δfϕₜ{s,t,<:LenseFlowOp{I}}}, (δf,δϕ)::FΦTuple) where {s,t,I} =
    FieldTuple(I((v,t,y)->negδvelocityᴴ!(v,J'.L,y,t),FieldTuple(Ł(J'.fₛ),Ð(δf),Ð(δϕ)),s,t)[2:3]...)


# lensing velocities
 velocity!(v::Field, L::LenseFlow, f::Field, t::Real) = (@. v = L.∇ϕ' ⨳ $(inv(I + t*L.Hϕ)) ⨳ $(Ł(∇ᵢ*f)))
velocityᴴ!(v::Field, L::LenseFlow, f::Field, t::Real) = (@. v = Ł(∇ᵢ' ⨳ (Ł(f) * (inv(I + t*L.Hϕ) ⨳ L.∇ϕ))))
# Jacobian velocities
function δvelocity!((f′,δf′)::FieldTuple, L::LenseFlow, f::Field, δf::Field, δϕ::Field, t::Real, ∇δϕ, Hδϕ)

    @unpack ∇ϕ,Hϕ = L
    M⁻¹ = Ł(inv(I + t*Hϕ))
    ∇f  = Ł(∇*f)
    ∇δf = Ł(∇*δf)

    @. f′  =  ∇ϕ' ⨳ M⁻¹ ⨳ ∇f
    @. δf′ = (∇ϕ' ⨳ M⁻¹ ⨳ ∇δf) + (∇δϕ' ⨳ M⁻¹ ⨳ ∇f) - t*(∇ϕ' ⨳ M⁻¹ ⨳ Hδϕ ⨳ M⁻¹ ⨳ ∇f)

end
""" ODE velocity for the negative transpose Jacobian flow """
function negδvelocityᴴ!((f′,δf′,δϕ′)::FieldTuple, L::LenseFlow, f::Field, δf::Field, δϕ::Field, t::Real)

    Łδf        = Ł(δf)
    M⁻¹        = Ł(inv(I + t*L.Hϕ))
    ∇f         = Ł(∇*f)
    M⁻¹_δfᵀ_∇f = Ł(M⁻¹ * (Łδf' * ∇f))
    M⁻¹_∇ϕ     = Ł(M⁻¹ * L.∇ϕ)

    @. f′  = L.∇ϕ' ⨳ M⁻¹ ⨳ ∇f
    @. δf′ = Ł(∇' ⨳ (Łδf ⨳ M⁻¹_∇ϕ))
    @. δϕ′ = Ł(∇' ⨳ (M⁻¹_δfᵀ_∇f) + t⨳(∇' ⨳ (∇' ⨳ (M⁻¹_∇ϕ ⨳ M⁻¹_δfᵀ_∇f'))'))

end


## CachedLenseFlow

# This is a version of LenseFlow that precomputes the inverse magnification
# matrix, M⁻¹, and the p vector, p = M⁻¹⋅∇ϕ, when it is constructed. The regular
# version of LenseFlow computes these on the fly during the integration, which
# is faster if you only apply the lensing operator or its Jacobian once.
# However, *this* version is faster is you apply the operator or its Jacobian
# several times for a given ϕ. This is useful, for example, during Wiener
# filtering with a fixed ϕ, or computing the likelihood gradient which involves
# lensing and 1 or 2 (depending on parametrization) Jacobian evaluations all
# with the same ϕ.


struct CachedLenseFlow{N,t₀,t₁,ŁΦ<:Field,ÐΦ<:Field,ŁF<:Field,ÐF<:Field} <: LenseFlowOp{jrk4{N},t₀,t₁}
    L   :: LenseFlow{jrk4{N},t₀,t₁,ŁΦ}
    
    # p and M⁻¹ quantities precomputed at every time step
    p   :: Dict{Float16,SVector{2,ŁΦ}}
    M⁻¹ :: Dict{Float16,SMatrix{2,2,ŁΦ}}
    
    # f type memory 
    memŁf  :: ŁF
    memÐf  :: ÐF
    memŁvf :: SVector{2,ŁF}
    memÐvf :: SVector{2,ÐF}
    
    # ϕ type memory
    memŁϕ  :: ŁΦ
    memÐϕ  :: ÐΦ
    memŁvϕ :: SVector{2,ŁΦ}
    memÐvϕ :: SVector{2,ÐΦ}
end
CachedLenseFlow{N}(ϕ) where {N} = cache(LenseFlow{jrk4{N}}(ϕ))
function cache(L::LenseFlow{jrk4{N},t₀,t₁},f) where {N,t₀,t₁}
    ts = linspace(t₀,t₁,2N+1)
    p, M⁻¹ = Dict(), Dict()
    for (t,τ) in zip(ts,τ.(ts))
        M⁻¹[τ] = inv(sqrt_gⁱⁱ(f) + t*L.Hϕ)
        p[τ]  = (L.∇ϕ' ⨳ M⁻¹[τ])'
    end
    Łf,Ðf = Ł(f),Ð(f)
    Łϕ,Ðϕ = Ł(L.∇ϕ[1]),Ð(L.∇ϕ[1])
    CachedLenseFlow{N,t₀,t₁,typeof(Łϕ),typeof(Ðϕ),typeof(Łf),typeof(Ðf)}(
        L, p, M⁻¹, 
        similar(Łf), similar(Ðf), similar.(@SVector[Łf,Łf]), similar.(@SVector[Ðf,Ðf]),
        similar(Łϕ), similar(Ðϕ), similar.(@SVector[Łϕ,Łϕ]), similar.(@SVector[Ðϕ,Ðϕ]),
    )
end
cache(L::CachedLenseFlow) = L
τ(t) = Float16(t)

# velocities for CachedLenseFlow which use the precomputed quantities and preallocated memory

# the way these velocities work is that they unpack the preallocated fields
# stored in L.mem* into variables with more meaningful names, which are then
# used in a bunch of in-place (eg mul!, Ł!, etc...) functions. note the use of
# the @! macro, which just switches @! x = f(y) to f!(x,y) for easier reading. 

function velocity!(v::Field, L::CachedLenseFlow, f::Field, t::Real)
    Ðf, Ð∇f, Ł∇f = L.memÐf, L.memÐvf,  L.memŁvf
    p = L.p[τ(t)]
    
    @! Ðf  = Ð(f)
    @! Ð∇f = ∇ᵢ*Ðf
    @! Ł∇f = Ł(Ð∇f)
    @⨳ v  = p' ⨳ Ł∇f
end

function velocityᴴ!(v::Field, L::CachedLenseFlow, f::Field, t::Real)
    Łf, Łf_p, Ð_Łf_p = L.memŁf, L.memŁvf, L.memÐvf
    p = L.p[τ(t)]
    
    @! Łf = Ł(f)
    @! Łf_p = Łf * p
    @! Ð_Łf_p = Ð(Łf_p)
    @! v = ∇' * Ð_Łf_p
end

function negδvelocityᴴ!((df_dt, dδf_dt, dδϕ_dt)::FieldTuple, L::CachedLenseFlow, (f, δf, δϕ)::FieldTuple, t::Real)
    
    p   = L.p[τ(t)]
    M⁻¹ = L.M⁻¹[τ(t)]
    
    # dδf/dt
    Łδf, Łδf_p, Ð_Łδf_p = L.memŁf, L.memŁvf, L.memÐvf
    @! Łδf     = Ł(δf)
    @! Łδf_p   = Łδf * p
    @! Ð_Łδf_p = Ð(Łδf_p)
    @! dδf_dt  = ∇' * Ð_Łδf_p
    
    # df/dt
    Ðf, Ð∇f, Ł∇f = L.memÐf, L.memÐvf,  L.memŁvf
    @! Ðf     = Ð(f)
    @! Ð∇f    = ∇*Ðf
    @! Ł∇f    = Ł(Ð∇f)
    @⨳ df_dt  = p' ⨳ Ł∇f

    # dδϕ/dt
    δfᵀ_∇f, M⁻¹_δfᵀ_∇f, Ð_M⁻¹_δfᵀ_∇f = L.memŁvϕ, L.memŁvϕ, L.memÐvϕ
    @! δfᵀ_∇f       = Łδf' * Ł∇f      # change to Łδf' once thats implemented
    @! M⁻¹_δfᵀ_∇f   = M⁻¹ * δfᵀ_∇f
    @! Ð_M⁻¹_δfᵀ_∇f = Ð(M⁻¹_δfᵀ_∇f)
    @! dδϕ_dt       = ∇' * Ð_M⁻¹_δfᵀ_∇f
    memÐϕ = L.memÐϕ
    for i=1:2, j=1:2
        dδϕ_dt .+= (@! memÐϕ = ∇[i] * (@! memÐϕ = ∇[j] * (@! memÐϕ = Ð(@. L.memŁϕ = t * p[j] * M⁻¹_δfᵀ_∇f[i]))))
    end
    
    FieldTuple(df_dt, dδf_dt, dδϕ_dt)
    
end
# no specialized version for these (yet):
δvelocity!(v_f_δf, L::CachedLenseFlow, args...) = δvelocity!(v_f_δf, L.L, args...)

# changing integration endpoints causes a re-caching (although swapping them does not)
_getindex(L::CachedLenseFlow{N,t₀,t₁}, ::→{t₀,t₁}) where {t₀,t₁,N} = L
_getindex(L::CachedLenseFlow{N,t₁,t₀}, ::→{t₀,t₁}) where {t₀,t₁,N} = CachedLenseFlow(L.L[t₀→t₁],L.p,L.M⁻¹)
_getindex(L::CachedLenseFlow,          ::→{t₀,t₁}) where {t₀,t₁}   = cache(L.L[t₀→t₁])

# ud_grading lenseflow ud_grades the ϕ map
ud_grade(L::LenseFlow{I,t₀,t₁}, args...; kwargs...) where {I,t₀,t₁} = LenseFlow{I,t₀,t₁}(ud_grade(L.ϕ,args...;kwargs...))
ud_grade(L::CachedLenseFlow, args...; kwargs...)  = cache(ud_grade(L.L,args...;kwargs...))

"""
Solve for y(t₁) with 4th order Runge-Kutta assuming dy/dt = F(t,y) and y(t₀) = y₀

Arguments
* F! : a function F!(v,t,y) which sets v=F(t,y)
"""
function jrk4(F!::Function, y₀, t₀, t₁, nsteps)
    h = (t₁-t₀)/nsteps
    y = copy(y₀)
    k₁, k₂, k₃, k₄, y′ = @repeated(similar(y₀),5)
    for t in linspace(t₀,t₁,nsteps+1)[1:end-1]
        @! k₁ = F!(t, y)
        @! k₂ = F!(t + (h/2), (@. y′ = y + (h/2)*k₁))
        @! k₃ = F!(t + (h/2), (@. y′ = y + (h/2)*k₂))
        @! k₄ = F!(t +   (h), (@. y′ = y +   (h)*k₃))
        @. y += h*(k₁ + 2k₂ + 2k₃ + k₄)/6
    end
    return y
end
