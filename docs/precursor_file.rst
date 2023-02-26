Precursor parameters file
==========================

An example of a precursor parameters file can be found in the
`Examples <https://github.com/MrCheatak/FEBID_py/tree/master/Examples>`_ folder of the repository.

Precursor parameters list:
---------------------------
Base parameters:

- **name** – a common name of the selected precursor
- **formula** - a chemical formula of the precursor ,i,e 'Me3PtCpMe'
- **molar_mass_precursor** – molecular mass of the precursor molecule, g/mol
- **max_density** - maximum site density of the precursor, 1/nm^2
- **dissociated_volume** – deposited material volume resulting from dissociation of s single molecule, nm^3
- **sticking_coefficient** – a probability that a precursor molecule adheres to the surface upon collision
- **P_vap**: precursor vapor pressure in the chamber, Pa

Dissociation:

- **cross_section** – precursor molecule integral dissociation cross-section, nm^2

Diffusion:

- **diffusion_coefficient** – surface diffusion coefficient , nm^2/s
- **diffusion_activation_energy*** – activation energy of the diffusion in its Arrhenius equation, eV
- **diffusion_prefactor*** – prefactor in diffusion Arrhenius equation, nm^2/s

Desorption:

- **residence_time** – a mean time a precursor molecule stays on the surface, µs
- **adsorption_activation_energy*** – activation energy of the adsorption in the residence time Arrhenius equation, eV
- **desorption_attempt_frequency*** – a frequency, at which a molecule attempts to desorb from the surface, Hz


Deposit parameters list:
--------------------------

- **deposit** – chemical formula reflecting resulting deposit composition
- **molar_mass_deposit** – molecular mass of the given formula, g/mol
- **SE_emission_activation_energy** – energy required to emit a secondary electron, eV
- **SE_mean_free_path** – secondary electron mean free path nm
- **average_element_number** – average or effective atomic number of the given formula
- **average_element_mol_mass** – average molecular mass of the given formula g/mol
- **average_density** – deposit mass density, g/cm^3
- **thermal_conductivity** – thermal conductivity of the bulk deposit, W/nm/K

**\*** – parameters required for temperature tracking



Heat capacity
'''''''''''''''
Target materials via FEBID are numerous: Pt, Au, Ag, Fe, Co, Re, Cu etc. Although it is a rare case,
when the deposited material is pure and usually represents target material embedded into amorphous carbonaceous matrix.
The heat capacity for such amorphous materials is estimated volumetrically:

:math:`\overline{c}_p=V_A\cdot c_{p_A}+V_B\cdot c_{p_B}`,

where
    :math:`V_A` and :math:`V_B` are volume fractions of the phases
    :math:`c_{p_A}` and :math:`c_{p_B}` are heat capacities of the phases A ans B