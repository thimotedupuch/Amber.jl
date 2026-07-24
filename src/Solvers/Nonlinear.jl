function _jacobian(f,z;h=sqrt(eps(Float64)))
    y=f(z); J=zeros(eltype(y),length(y),length(z))
    for j in eachindex(z)
        δ=h*max(1,abs(z[j])); zz=copy(z); zz[j]+=δ; J[:,j]=(f(zz)-y)/δ
    end
    J
end

function _newton(cc,z0,previous,t,α;reltol=1e-7,abstol=1e-10,maxiters=60,mode=:time,source_scale=1.,gmin=0.)
    z=copy(z0)
    for it in 1:maxiters
        r,J=residual_jacobian(cc,z,previous,t,α;mode,source_scale,gmin)
        numerical_floor=32eps(Float64)*max(opnorm(J,Inf)*max(norm(z,Inf),1),1)
        norm(r,Inf)<abstol+numerical_floor&&return z,it,true
        Δ=try -(J\r) catch; -(J+spdiagm(0=>fill(1e-12,cc.n)))\r end
        damping=1.; nr=norm(r)
        while damping>1/128
            candidate=z+damping*Δ
            candidate_residual=residual(cc,candidate,α==0 ? zero(candidate) : α.*(candidate.-previous),t;mode,source_scale,gmin)
            norm(candidate_residual)<=nr&&break
            damping/=2
        end
        z+=damping*Δ
    end
    z,maxiters,false
end
