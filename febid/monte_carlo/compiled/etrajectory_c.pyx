# distutils: language = c++
#cython: language_level=3
#cython: cdivision=True
#in particular enables special integer division
import traceback

import cython
from cython.parallel cimport prange
import numpy as np
cimport numpy as np
from libc.stdlib cimport rand, srand, RAND_MAX, malloc, realloc, free
from libc.time cimport time

from libc.math cimport fabs, sqrt, log, cos, sin, pi, NAN, isnan
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cpython.array cimport array, clone
from libcpp.vector cimport vector


# @cython.boundscheck(False) # turn off bounds-checking for entire function
# @cython.wraparound(False)  # turn off negative index wrapping for entire function


"""Memory management and coercion to Python"""
# Here are a couple of explanations about the utilized memory management and coercion between Python and Cython,
# because the method used here is not explicitly described anywhere.
# Python and Cython have several common data types that are converted automatically, some of the more specific
# or user-defined ones has to be coerced manually.
# The task of recording a trajectory's successive scattering points requires an expendable data structure,
# due to a virtually random length of each trajectory. On Python level, 'list' serves such a purpose pretty well.
# While there are no expandable data structures in C standard library (malloc()/realloc() variables are not
# automatically managed), 'vector' from standard C++ library is exactly the suitable type.
# Cython provides a pretty neat memoryview protocol that can be connected with almost any array-like data structure
# and then be sent back and used in Python. But it is not implemented for C++ vectors, thus exposing it to Python
# (and Numpy) is on the shoulders of a programmer.
# There are two ideas that has to be kept in mind while trying to expose C-level variables to Python:
# 1. A pointer to the memory, where data is stored, must be handed to a Python object
# 2. A buffer protocol has to be set up in order for Numpy to be able to get
# the ownership of the memory (without copying).
#
# A template of such setup is provided in Cython docs and used here.
# A class named BuffVector takes in the vector itself, the number of columns and the number of dimensions,
# makes it accessible for Numpy via __getbuffer__ method, so that when np.asarray(obj<BuffVector>) is called
# vector is converted to a numpy array without copying.
# While here this class is used purely as a temporary variable between Numpy and vector, it can be extended
# to become a self-consistent object that supports addition, modification and removal of the data.
# The described routine is used only after the simulation has concluded
# and arrays for every trajectory are collected in a list.
# Simulation itself uses nested vectors: vector[vector[double]] for all three types of records: point, energy and mark.
# It is important to point out here, that point components (z,y,x) of a trajectory are recorded in the same row.
# This layout allows the use of 'strides' in the buffer protocol (in the BuffVector class), which basically tells Numpy
# that our data is 2D and contiguous in memory (vectors are stored contiguously) and enables Numpy to take the memory
# 'as it is' without copying.
#
# The use of the described method allows us to generate electron trajectories in the exact same form they are
# generated by original Python script and thus be pipelined further without the need of adapting receiver code.

cdef NA = 6.022141E23 # Avogadro number

cdef struct Coordinate:
    double z
    double y
    double x

cdef Coordinate coordinate(double z, double y, double x):
    cdef Coordinate c
    c.z = z
    c.y = y
    c.x = x
    return c

cdef void push_back_coordinate(vector[double] *v, Coordinate c):
    v.push_back(c.z)
    v.push_back(c.y)
    v.push_back(c.x)

cdef Coordinate from_mv(double[:] x):
    cdef Coordinate c
    c.z = x[0]
    c.y = x[1]
    c.x = x[2]
    return c

cdef struct Shape:
    int z
    int y
    int x

cdef struct Element:
    # Name of the material is excluded so far, as struct member cannot be a Python object
    # and C-strings are too complicated for the current internal use. Name is still stored on
    # the Python level.
    # bytes name
    double rho
    double Z
    double A
    double J # ionisation potential has to be calculated right after the creation
    int e
    double lambda_escape
    int mark

cdef class BuffVector:
    cdef Py_ssize_t ncols
    cdef Py_ssize_t shape[2]
    cdef Py_ssize_t strides[2]
    cdef Py_ssize_t ndim
    cdef vector[double] v

    def __cinit__(self, Py_ssize_t ncols, Py_ssize_t ndim, vector[double] vec):
        self.ndim = ndim
        self.ncols = ncols
        self.v = vec

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        cdef Py_ssize_t itemsize = sizeof(self.v[0])

        self.shape[0] = self.v.size() / self.ncols
        self.shape[1] = self.ncols

        # Stride 1 is the distance, in bytes, between two items in a row;
        # this is the distance between two adjacent items in the vector.
        # Stride 0 is the distance between the first elements of adjacent rows.
        self.strides[1] = <Py_ssize_t>(  <char *>&(self.v[1])
                                       - <char *>&(self.v[0]))
        self.strides[0] = self.ncols * self.strides[1]

        buffer.buf = <char *>&(self.v[0])
        buffer.format = 'd'                     # double
        buffer.internal = NULL                  # see References
        buffer.itemsize = itemsize
        buffer.len = self.v.size() * itemsize   # product(shape) * itemsize
        buffer.ndim = self.ndim
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = self.shape
        buffer.strides = self.strides
        buffer.suboffsets = NULL                # for pointer arrays only

    def __releasebuffer__(self, Py_buffer *buffer):
        pass


cdef class Electron:
    cdef:
        Coordinate point
        Coordinate point_prev
        Coordinate direction
        double E
        double ctheta
        double stheta
        double psi

    def __cinit__(self, Coordinate point, double E):
        self.point = point
        self.E = E
        self.direction = coordinate(1,0,0)
        
    cdef void set_point(self, double z, double y, double x):
        self.point.z = z
        self.point.y = y
        self.point.x = x
        
    cdef void set_point_prev(self, double z, double y, double x):
        self.point_prev.z = z
        self.point_prev.y = y
        self.point_prev.x = x
        
    cdef void add_point(self, Coordinate point):
        self.point_prev = self.point
        self.point = point

    cdef (int, int, int) get_indices(self, int cell_dim):
        return <int>(self.point.z/cell_dim), <int>(self.point.y/cell_dim), <int>(self.point.x/cell_dim)

    cdef void get_angles(self, double a):
        """
        Generates cos and sin of lateral angle and the azimuthal angle

        :param a: alpha at the current step
        :return:
        """

        # Important note_: the equation for ctheta is unstable and oscillates, producing values a bit below -1.
        # In the next line, it produces a negative value under the sqrt() and eventually leading to a nan value.
        # After that the program will ultimately crash
        # This is fixed by truncating the digits(double->float) that carry the error (~e-12)
        # For analysis, check the function for alpha
        cdef double rnd1 = rnd_uniform(0, 1)
        cdef double rnd2 = rnd_uniform(0, 1)
        self.ctheta = <float>(1.0 - 2.0 * a * rnd1 / (1.0 + a - rnd1))  # scattering angle cosines , 0 <= angle <= 180˚, it produces an angular distribution that is obtained experimentally (more chance for low angles)
        self.stheta = sqrt(1.0 - self.ctheta * self.ctheta)  # scattering angle sinus
        self.psi = 2.0 * pi * rnd2  # azimuthal scattering angle
        if isnan(self.ctheta) or isnan(self.stheta) or isnan(self.psi):
            print(f'ctheta, stheta, psi: {self.ctheta, self.stheta, self.psi}')
            print(f'rnd1, rnd2, a, E: {rnd1, rnd2, a, self.E}')
            raise ValueError('NAN encountered in angles!')

    cdef void get_direction(self):
        cdef float cc, cb, ca, AM, AN, V1, V2, V3, V4
        # if cz == 0.0: cz = 0.00001
        # Coefficients for calculating direction cosines
        if self.direction.z == 0:
            self.direction.z = 0.00001
        AM = - self.direction.x / self.direction.z
        AN = 1.0 / sqrt(1.0 + AM ** 2)
        V1 = AN * self.stheta
        V2 = AN * AM * self.stheta
        V3 = cos(self.psi)
        V4 = sin(self.psi)
        # New direction cosines
        # On every step a sum of squares of the direction cosines is always a unity
        ca = self.direction.x * self.ctheta + V1 * V3 + self.direction.y * V2 * V4
        cb = self.direction.y * self.ctheta + V4 * (self.direction.z * V1 - self.direction.x * V2)
        cc = self.direction.z * self.ctheta + V2 * V3 - self.direction.y * V1 * V4
        if ca == 0:
            ca = 0.0000001
        if cb == 0:
            cb = 0.0000001
        if cc == 0:
            cc = 0.0000001
        self.direction = coordinate(cc, cb, ca)

    cdef (double, double, double) get_next_point(self, double a, double step):
        cdef double z, y, x
        self.get_angles(a)
        self.get_direction()
        self.add_point(self.point)
        self.point.z = self.point.z - self.direction.z * step
        self.point.y = self.point.y + self.direction.y * step
        self.point.x = self.point.x + self.direction.x * step

    cdef Coordinate check_boundaries(self, Shape dims):
        """
        Check if the given (z,y,x) position is inside the simulation chamber.
        If bounds are crossed, return corrected position

        :param z:
        :param y:
        :param x:
        :return:
        """
        cdef double z, y, x, min
        cdef unsigned char flag = 1
        z = self.point.z
        y = self.point.y
        x = self.point.x
        # If the border value is not zero, coordinates have to be checked against it, not against zero
        min = 1e-6
        if min <= x < dims.x:
            pass
        else:
            flag = 0
            if x < min:
                x = 0.000001
            else:
                x = dims.x - 0.0000001

        if min <= y < dims.y:
            pass
        else:
            flag = 0
            if y < min:
                y = 0.000001
            else:
                y = dims.y - 0.000001

        if min <= z < dims.z:
            pass
        else:
            flag = 0
            if z < min:
                z = 0.000001
            else:
                z = dims.z - 0.000001
        if flag:
            return coordinate(NAN, NAN, NAN)
        else:
            return coordinate(z, y, x)


cdef class SimulationVolume:
    cdef:
        double[:,:,:] grid
        unsigned char[:,:,:] surface
        int cell_dim
        int z_top
        Shape shape
        Shape shape_abs

    def __cinit__(self, double[:,:,:] grid, unsigned char[:,:,:] surface, int cell_dim):
        self.grid = grid
        self.surface = surface
        self.cell_dim = cell_dim
        self.set_shape()
        self.get_z_top()

    cdef void set_shape(self):
        self.shape.z = self.grid.shape[0]
        self.shape.y = self.grid.shape[1]
        self.shape.x = self.grid.shape[2]
        self.shape_abs.z = self.shape.z * self.cell_dim
        self.shape_abs.y = self.shape.y * self.cell_dim
        self.shape_abs.x = self.shape.x * self.cell_dim

    cdef void get_z_top(self):
        self.z_top = (np.nonzero(self.surface)[0].max() - 1) * self.cell_dim


####################################################################################
################## Initialization ##################################################
####################################################################################
cpdef vector[Element] get_materials(list materials_py):
    # cdef Element_py m
    cdef Element m_unit 
    cdef vector[Element] materials
    for m in materials_py:
        # m_unit.name = m.name # excluded due to string usage limitations
        m_unit.rho = m.rho
        m_unit.Z = m.Z
        m_unit.A = m.A
        m_unit.J = m.J
        m_unit.e = m.e
        m_unit.lambda_escape = m.lambda_escape
        m_unit.mark = m.mark
        materials.push_back(m_unit)
    return materials


####################################################################################
################## Main algorithm ##################################################
####################################################################################
cpdef list start_sim(double E0, double Emin, double[:] y0, double[:] x0, int cell_dim, double[:,:,:] grid, unsigned char[:,:,:] surface, list materials_py):
    cdef:
        vector[Element] materials
        vector[vector[double]] t, e, m
        SimulationVolume vol
        list passes
    print('Caching materials...', end='')
    materials = get_materials(materials_py)
    print('Getting volume parameters...', end='')
    vol = SimulationVolume.__new__(SimulationVolume, grid, surface, cell_dim)
    # print('Initialized Elements and Volume successfully...')
    # print(vol.cell_dim, vol.shape, vol.shape_abs, vol.z_top)
    try:
        map_trajectory_c(&t, &e, &m, y0, x0, E0, Emin, vol, materials)
    except Exception as ex:
        print(f'An error occurred in \'start_sim\': {ex.args}')
        traceback.print_exc()
        raise ex

    return trajectory_vector_to_np_list(t, e, m)

cdef int map_trajectory_c(vector[vector[double]] *trajectories, vector[vector[double]] *energies, vector[vector[double]] *masks, double[:] y0, double[:] x0, double E0, double Emin, SimulationVolume grid, vector[Element] materials) except -1:
    cdef:
        vector[double] energy
        vector[double] trajectory
        vector[double] mask
        double delta[3], c[3], c1[3]
        double[:] vec = delta
        double[:] crossing = c
        double[:] crossing1 = c1
        Coordinate coord, check
        Electron e
        Element material
        unsigned char flag = 0
        int g, i, j, k
        double a, step

    srand(time(NULL))
    for g in range(x0.shape[0]):
        flag = 0
        coord = coordinate(grid.shape_abs.z - 0.001, y0[g], x0[g]) # the very first point is at the top of the volume
        e = Electron.__new__(Electron, coord, E0)
        push_back_coordinate(&trajectory, e.point)
        # print(f'\nEntry, Recorded point, energy: {e.point, e.E}')
        energy.push_back(e.E)
        e.add_point(coord)

        # coord = coordinate(grid.z_top - 0.001, y0[g], x0[g]) # the incident point is sunk into the solid a tiny bit
        # e.add_point(coord)
        # push_back_coordinate(&trajectory, e.point)
        # energy.push_back(e.E)

        i, j, k = e.get_indices(grid.cell_dim)
        if grid.grid[i,j,k] > -1:
            e.point.z = max_index_less_double(grid.grid[:,j,k], 0) * grid.cell_dim + grid.cell_dim - 0.001
            push_back_coordinate(&trajectory, e.point)
            energy.push_back(e.E)
            # print(f'Incident, Recorded point, energy: {e.point, e.E}')
            mask.push_back(0.0)
            if e.point.z == grid.cell_dim:
                trajectories.push_back(trajectory)
                energies.push_back(energy)
                masks.push_back(mask)
                trajectory.clear()
                energy.clear()
                mask.clear()
                continue
            material = materials[0]

        while e.E > Emin:
            a = get_alpha(e.E, material.Z)
            step = get_step(e.E, &material, a)
            e.get_next_point(a, step)
            check = e.check_boundaries(grid.shape_abs)
            if not isnan(check.z):
                flag = 1
                e.point = check
                delta[0] = e.point.z - e.point_prev.z
                delta[1] = e.point.y - e.point_prev.y
                delta[2] = e.point.x - e.point_prev.x
                step = det_c(delta)
            i, j, k = e.get_indices(grid.cell_dim)
            if grid.grid[i, j, k] < 0:
                e.E = e.E + get_Eloss_c(e.E,&material) * step
                push_back_coordinate(&trajectory, e.point)
                energy.push_back(e.E)
                mask.push_back(1.0)
                # print(f'Solid, Recorded point, energy: {e.point, e.E}, exiting: {flag}')
                if grid.grid[i, j, k] != material.mark:
                    if grid.grid[i, j, k] == -2:
                        material = materials[0]
                    if grid.grid[i, j, k] == -1:
                        material = materials[1]
            else:
                flag = get_next_crossing(e.point_prev, e.direction, grid, crossing, crossing1)
                # print(f'Got crossings: {c, c1}')
                e.point = from_mv(crossing)
                delta[0] = e.point.z - e.point_prev.z
                delta[1] = e.point.y - e.point_prev.y
                delta[2] = e.point.x - e.point_prev.x
                e.E = e.E + get_Eloss_c(e.E,&material) * det_c(delta)
                push_back_coordinate(&trajectory, e.point)
                energy.push_back(e.E)
                # print(f'Void, Recorded point, energy: {e.point, e.E}')
                if flag == 2:
                    # print('Missed surface!')
                    mask.push_back(0.0)
                if flag < 2:
                    mask.push_back(1.0)
                    e.add_point(from_mv(crossing1))
                    push_back_coordinate(&trajectory, e.point)
                    energy.push_back(e.E)
                    mask.push_back(0.0)
                    # print(f'Void, exiting, Recorded point, energy: {e.point, e.E}')
            if flag > 0:
                flag = 0
                break
        trajectories.push_back(trajectory)
        energies.push_back(energy)
        masks.push_back(mask)
        trajectory.clear()
        energy.clear()
        mask.clear()

    return 1


####################################################################################
################## Physical formulas ###############################################
####################################################################################

cdef double get_alpha(double E, double Z):
    # Alpha can take values in a range [0.0001: 0.84]
    # assuming energy may vary from 0.1 (cut-off) to 30 keV
    # and element number varying from 1 to 116
    return 3.4E-3*Z**0.67/E

cdef double get_step(double E, Element *material, double a):
    cdef float rnd = rand() / (RAND_MAX * 1.00011) + 0.00001 # produces a random number in range[1E-5, 0.9999] with slight overlap (~1E-8)
    return -log(rnd) * get_lambda_el(E, material.Z, material.rho, material.A, a)

cdef double get_Eloss_c(double E, Element *material):
    return -7.85E-3 * material.rho * material.Z / (material.A * E) * log(1.166 * (E / material.J + 0.85))

cdef inline double get_sigma(double E, double Z, double a):
    return 5.21E-7 * Z ** 2 / E ** 2 * 4.0 * 3.14159 / (a * (1.0 + a)) * (
                (E + 511.0) / (E + 1022.0)) ** 2

cdef inline double get_lambda_el(double E, double Z, double rho, double A, double a):
    cdef float sigma = get_sigma(E, Z, a)
    return A / (6.022141E23 * rho * 1.0E-21 * sigma)


cdef inline float get_j(double Z):
    return (9.76 * Z + 58.5 / Z ** 0.19) * 1.0E-3

####################################################################################
################## Cell traversal ##################################################
####################################################################################
@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef signed char get_next_crossing(Coordinate point, Coordinate vec, SimulationVolume grid, double[:] crossing, double[:] crossing1) except -1:
    # 'c' in the end of the names stands for C-arrays
    cdef:
        double p0c[3]
        double pnc[3], directionc[3], tc[3], step_tc[3], deltac[3]
        signed char signc[3]
        unsigned char temp[3], temp1[3]
        double[:] p0=p0c
        double[:] pn=pnc
        double[:] direction=directionc
        double[:] t=tc
        double[:] step_t = step_tc
        double[:] delta=deltac
        int step[3]
        double t_min, min = 1e-6
        signed char[:] sign = signc
        unsigned char flag
        int i = 0

    p0c[0] = point.z
    p0c[1] = point.y
    p0c[2] = point.x
    # print(f'p0: {p0c}')
    directionc[0] = - vec.z
    directionc[1] = vec.y
    directionc[2] = vec.x
    # print(f'dir: {directionc}')
    step[0] = grid.shape_abs.z
    step[1] = grid.shape_abs.y
    step[2] = grid.shape_abs.x

    sign_double(direction, sign)
    # print(f'sign{signc[0], signc[1], signc[2]}')
    for i in range(sign.shape[0]):
        if sign[i] == 1:
            temp[i] = 1
        else:
            temp[i] = 0
    # print(f'sign==1: {temp[0], temp[1], temp[2]}')
    for i in range(3):
        tc[i] = fabs((-p0[i] + temp[i]*step[i])/directionc[i])
    # print(f't: {tc}')
    t_min, _ = arr_min(t)
    # print(f't_min: {t_min}')
    for i in range(3):
        pn[i] = p0[i] + t_min * directionc[i]
    # print(f'pn: {pnc}')
    for i in range(3):
        if pn[i] >= step[i]:
            pn[i] = step[i] - 0.000001
        elif pn[i] < min:
            pn[i] = 0.000001

    # print(f'pnc_corr: {pnc}')
    sub_double(pn, p0, direction)
    # print(f'dir: {directionc}')
    for i in range(3):
        if directionc[i] == 0:
            directionc[i] = rnd_uniform(-0.000001, 0.000001)
        step[i] = sign[i] * grid.cell_dim

    # print(f'step: {step}')
    for i in range(3):
        step_tc[i] = step[i]/directionc[i]
    # print(f'step_tc: {step_tc}')
    for i in range(3):
        deltac[i] = -(p0[i]%grid.cell_dim)
    # print(f'delta: {deltac}')
    for i in range(delta.shape[0]):
        if delta[i] == 0:
            temp1[i] = 1
        else:
            temp1[i] = 0
    # print(f'delta==0: {temp1[0], temp1[1], temp1[2]}')
    for i in range(3):
        tc[i] = fabs((deltac[i] + temp[i]*grid.cell_dim + temp1[i]*step[i])/directionc[i])
        if signc[i] == 1:
            signc[i] = 0
    # print(f't: {tc}')
    # print(f'(sign==1)=0: {signc[0], signc[1], signc[2]}')
    flag = get_surface_crossing_c(grid.surface, grid.cell_dim, p0, direction, t, step_t, sign, crossing)
    if flag:
        # i,j,k = int(p0[0]/grid.cell_dim), int(p0[1]/grid.cell_dim), int(p0[2]/grid.cell_dim)
        # print(f'\nMissed surface: {i,j,k}, cell: {grid.grid[i,j,k]} \n'
        #       f'p0: {p0c}, dir_c: {vec} \n'
        #       f'pn: {pnc}, direction: {directionc}\n'
        #       f'delta: {deltac}, sign: {signc[0], signc[1], signc[2]}, step: {step}, \n'
        #       f'step_t: {step_tc}, t: {tc}, \n'
        #       f'c: {crossing[0], crossing[1], crossing[2]},'
        #       f'c1: {crossing1[0], crossing1[1], crossing1[2]}')
        crossing = pnc
        return 2
    # Here the scattering points are 'pushed' into the solid
    # Otherwise they appear at a face of a grid cell which may cause uncertanty
    # weather the scattering occurred at the surface or in the solid
    crossing[0] -= sign[0] * 0.001 # pusing the scattering point a tiny bit into the solid
    crossing[1] -= sign[1] * 0.001
    crossing[2] -= sign[2] * 0.001
    flag = get_solid_crossing_c(grid.grid, grid.cell_dim, p0, direction, t, step_t, sign, crossing1)
    if flag:
        crossing1 = pnc
    else:
        crossing1[0] += sign[0] * 0.001 # pusing the scattering point a tiny bit into the solid
        crossing1[0] += sign[0] * 0.001
        crossing1[0] += sign[0] * 0.001
    return flag

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef unsigned char get_solid_crossing_c(double[:,:,:] grid, int cell_dim, double[:] p0, double[:] direction, double[:] t, double[:] step_t, signed char[:] sign, double[:] coord) nogil except -1:
    cdef:
        char ind
        int i
        double next_t
        int index[3]
    while True:  # iterating until all the cells are traversed by the ray
        next_t, ind = arr_min(t)  # minimal t-value corresponds to the box wall crossed
        if next_t > 1:  # finish if trajectory ends inside a cell (t>1); this essentially means that even if next point is exactly at the next boundary, it finishes the loop
            # for i in range(3):
            #     coord[i] = p0[i] + next_t * direction[i]
            #     index[i] = <int> (coord[i] / cell_dim)
            # index[ind] = index[ind] + sign[ind]
            # if grid[index[0], index[1], index[2]] <= -1:
            #     return False
            return True
        for i in range(3):
            coord[i] = p0[i] + next_t * direction[i]
            index[i] = <unsigned int> (coord[i]/cell_dim)
        # index[ind] = <unsigned int> (index[ind] + sign[ind])
        if grid[index[0], index[1], index[2]]<=-1:
            if coord[1] == 0 or coord[2] == 0:
                with gil:
                    print(f'Coords: {coord[0], coord[1], coord[2]}')
                    print(f'Index: {index[0], index[1], index[2]}')
                    print(f'Grid: {grid[index[0], index[1], index[2]]}')
            return False
        t[ind] = t[ind] + step_t[ind]  # going to the next wall

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef unsigned char get_surface_crossing_c(unsigned char[:,:,:] surface, int cell_dim, double[:] p0, double[:] direction, double[:] t, double[:] step_t, signed char[:] sign, double[:] coord) nogil except -1:
    cdef:
        char ind
        int i
        double next_t
        int index[3]
    while True:  # iterating until all the cells are traversed by the ray
        next_t, ind = arr_min(t)  # minimal t-value corresponds to the box wall crossed
        if next_t > 1:  # finish if trajectory ends inside a cell (t>1)
            # for i in range(3):
            #     coord[i] = pn[i]
            #     index[i] = <int> (p0[i] / cell_dim)
            # # print(f'Coord: {[coord[0], coord[1], coord[2]]} , Index: {index}, Sign: {[sign[0], sign[1], sign[2]]}')
            # if surface[index[0], index[1], index[2]]:
            #     return False
            return True
        for i in range(3):
            coord[i] = p0[i] + next_t * direction[i]
            index[i] = <unsigned int> (coord[i]/cell_dim)
        # index[ind] = <unsigned int> (index[ind] + sign[ind])
        # print(f'Coord: {[coord[0], coord[1], coord[2]]} , Index: {index}, Sign: {sign[ind]}, T, ind: {next_t, ind}')
        if surface[index[0], index[1], index[2]]:
            # print('')
            return False
        t[ind] = t[ind] + step_t[ind]  # going to the next wall

####################################################################################
################## Vectorized math #################################################
####################################################################################
@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef inline (double, char) arr_min(double[:] x) nogil:
    """
    Find the minimum value in the array(vector).

    :param x: input array, has to have a size of 3
    :return: (min value, index of min value)
    """
    cdef int i, n=0,
    cdef double min=x[0]
    for i in range(x.shape[0]):
        if x[i] < min:
            min = x[i]
            n = i

    return(min, n)

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef inline int amax(double[:] x) nogil except -1:
    """

    :param x: 
    :return: 
    """
    cdef int i, max
    for i in range(x.shape[0]):
        if x[i]<0:
            if i>max:
                max = i
    return max

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int sign_int(double[:] x, signed char[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        if x[i]>0:
            c[i] = 1
        elif x[i]<0:
            c[i] = -1
        else:
            c[i] = 0

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int sign_double(double[:] x, signed char[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        if x[i]>0:
            c[i] = 1
        elif x[i]<0:
            c[i] = -1
        else:
            c[i] = 0

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int equal_to_bool(signed char[:] x, int val, unsigned char[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        if x[i] == val:
            c[i] = 1
        else:
            c[i] = 0

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int equal_to_int(int[:] x, int val, unsigned char[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        if x[i] == i:
            c[i] = 1
        else:
            c[i] = 0

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int equal_to_double(double[:] x, int val, unsigned char[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        if x[i] == i:
            c[i] = 1
        else:
            c[i] = 0

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int max_index_less_double(double[:] x, double val) nogil except -1:
    cdef int ind = 0
    for i in range(x.shape[0]):
        if x[i] < val:
            if i > ind:
                ind = i
    return ind

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int sub_double(double[:] x, double[:] y, double[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        c[i] = x[i] - y[i]

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int add_double(double[:] x, double[:] y, double[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        c[i] = x[i] + y[i]

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int multc_double(double[:] x, double val, double[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        c[i] = x[i] * val

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int div_double(double[:] x, double[:] y, double[:] c) nogil except -1:
    cdef int i
    for i in range(x.shape[0]):
        c[i] = x[i] / y[i]

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef inline double det_c(double* vec) nogil except -1:
    """
    Find the length of a vector.

    :param vec: vector array
    :return: length
    """
    return sqrt(vec[0] * vec[0] + vec[1] * vec[1] + vec[2] * vec[2])

@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef inline double det_c_debug(double[:] vec) nogil except -1:
    return sqrt(vec[0] * vec[0] + vec[1] * vec[1] + vec[2] * vec[2])

cdef double rnd_uniform(double min, double max) nogil except -1:
    return rand() / (RAND_MAX * 1.0)*(max-min) + min


####################################################################################
################## Memory management ###############################################
####################################################################################
cdef list trajectory_vector_to_np_list(vector[vector[double]] ts, vector[vector[double]] es, vector[vector[double]] ms):
    cdef list passes = []
    cdef int i, j
    cdef BuffVector t, e, m
    for i in range(ts.size()):
        t = BuffVector.__new__(BuffVector, 3, 2, ts[i])
        e = BuffVector.__new__(BuffVector, 1, 1, es[i])
        m = BuffVector.__new__(BuffVector, 1, 1, ms[i])
        passes.append((np.asarray(t), np.asarray(e), np.asarray(m)))
        # print(passes[i])
    return passes

cdef list trajectory_vector_to_list(vector[vector[double]] ts, vector[vector[double]] es, vector[vector[double]] ms):
    cdef list passes=[], t=[], e =[], m=[]
    cdef int i, j
    for i in range(ts.size()):
        t.clear()
        e.clear()
        m.clear()
        for j in range(ts[i].size()):
            t.append(ts[i][j])
        for j in range(es[i].size()):
            e.append(es[i][j])
        for j in range(ms[i].size()):
            m.append(ms[i][j])
        passes.append((t, e, m))
        # print(passes[i])
    return passes