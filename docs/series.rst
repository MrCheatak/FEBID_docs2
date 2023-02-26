===================================
Setting up a series of simulations
===================================

Optimisation of pattern files, simulation input parameters or simulation of several structures may require
running a significant number of simulations. The package offers some simple automation features for such tasks.
Setting up a simulation series requires composing a Python script.

The first feature allows executing a sequence of simulations arising from consequently changing a single parameter.
A series of such simulations is regarded as a `scan`. Such scan can be carried out on any parameter from
the `Precursor <precursor_file.html>`_ or `Settings <settings_file.html>`_ file.

It is also possible to run a 2D scan, meaning another parameter is scanned for each value of the first parameter.

The second option is to run simulations by using a collection of pattern files. This mode requires that all the
desired pattern files are collected in a single folder, that has to be provided to the script.

.. note::
    Scanning only modifies the selected parameter(s). Thus, all other parameters as well as saving options and output
    directory have to be preset.

