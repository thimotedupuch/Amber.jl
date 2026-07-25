@testset "verification: representation invariance" begin
    @circuit FlatReference() begin
        gnd=ground(); input=node(); middle=node(); output=node()
        V1=voltage_source(input,gnd;dc=3V,ac=1V)
        R1=resistor(input,middle;value=1kΩ); C1=capacitor(middle,gnd;value=10nF)
        R2=resistor(middle,output;value=2kΩ); C2=capacitor(output,gnd;value=20nF)
        Load=resistor(output,gnd;value=10kΩ)
    end
    original=FlatReference(); reordered=deepcopy(original); reverse!(reordered.components)
    first_result=operating_point(original); second_result=operating_point(reordered)
    @test voltage(first_result,:middle)≈voltage(second_result,:middle) rtol=1e-12
    @test voltage(first_result,:output)≈voltage(second_result,:output) rtol=1e-12

    renamed=deepcopy(original)
    for (index,node) in enumerate(renamed.nodes)
        node isa Ground&&continue
        renamed.nodes[index]=Amber.Node(renamed,node.id,Symbol(:renamed_,node.id))
    end
    nodemap=Dict(node.id=>node for node in renamed.nodes)
    for component in renamed.components
        component.terminals=Amber.AbstractNode[nodemap[terminal.id] for terminal in component.terminals]
    end
    renamed_result=operating_point(renamed)
    @test sort(first_result.values[:,1])≈sort(renamed_result.values[:,1]) rtol=1e-12
end

