#!/bin/bash

# The name of the executable
execname="$1"
# Number of starting ranks (=num_procs_per_node)
numranks="$2"

# Number of sections
sections='-sections 1'
# Allow splitting sections during load balancing
split='-lbsplit'
# The Courant number (keep it 0.95)
courant='-courant 0.95'
# Number of threads
threads='-threads 1'
# VTK output frequency (every N seconds)
tout='-tout 120'
# iMPI adapt frequency (every N steps)
nimpiadapt='-nimpiadapt 50'
# Grid minimum depth
dmin='-dmin 8'
# Grid maximum depth
dmax='-dmax 20'
# Simulation time in seconds (normally 3 hrs)
tmax='-tmax 3600'
# Data file for displacement
fdispl='-fdispl /home/emily/nfs/workspace/samoa-data/tohoku_static/displ.nc'
# Data file for bathymetry
fbath='-fbath /home/emily/nfs/workspace/samoa-data/tohoku_static/bath_2014.nc'
# Enable/disable VTK output
xmlout='-xmloutput .false.'
# What is stestpoints (for Tohoku only)??
stestpoints='-stestpoints "545735.266126 62716.4740303,935356.566012 -817289.628677,1058466.21575 765077.767857"' 
# Ouput directory
outdir='/home/emily/nfs/workspace/isamoa/output'
if [[ $execname == *"impi"* ]]; then
	outdir+='/swe_impi'
else
	outdir+='/swe_mpi'
fi
rm -rf $outdir
mkdir $outdir
output_dir='-output_dir '$outdir
# Put all options together
all=$sections' '$split' '$courant' '$threads' '$tout' '$nimpiadapt' '$dmin' '$dmax' '$tmax' '$fdispl' '$fbath' '$xmlout' '$stestpoints' '$output_dir

#mpiexec -n 4 $execname $all >> console.out
srun -n $numranks $execname $all > $outdir/console.log
