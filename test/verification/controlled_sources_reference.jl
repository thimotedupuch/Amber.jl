@testset "verification: controlled-source equations" begin
    @circuit ControlledReference() begin
        gnd=ground(); control=node(); vccs_output=node(); vcvs_output=node(); cccs_output=node(); ccvs_output=node()
        Sense=voltage_source(control,gnd;dc=2V)
        RSense=resistor(control,gnd;value=1kΩ)
        G=transconductance(control,gnd,vccs_output,gnd;gm=3mA/V)
        RG=resistor(vccs_output,gnd;value=500Ω)
        E=voltage_controlled_voltage_source(control,gnd,vcvs_output,gnd;gain=4.)
        F=current_controlled_current_source(Sense,cccs_output,gnd;gain=5.)
        RF=resistor(cccs_output,gnd;value=100Ω)
        H=current_controlled_voltage_source(Sense,ccvs_output,gnd;transresistance=2kΩ)
    end
    result=operating_point(ControlledReference())
    sense_current=-2mA
    @test voltage(result,:vccs_output)[1]≈-3V rtol=1e-12
    @test voltage(result,:vcvs_output)[1]≈8V rtol=1e-12
    @test voltage(result,:cccs_output)[1]≈-5*100Ω*sense_current rtol=1e-12
    @test voltage(result,:ccvs_output)[1]≈2kΩ*sense_current rtol=1e-12
end
