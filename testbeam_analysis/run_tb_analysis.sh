!/bin/bash
set -e
# set -x


# Philosophy: This script is the upgraded "run_tb_analysis.sh". Extra features, but backwards-compatible.




##########
# Syntax #
##########



# Syntax: This script is run within the container as legacy "./run_tb_alignment.sh params/SPS202404/STD225SQ/007/STD225SQ.txt"
# Or using flag options "./run_tb_alignment.sh -p params/SPS202404/STD225SQ/007/STD225SQ.txt -t some_tag -a -b
# Note that all options listed below are optional.
# -p : params .txt file (can optionally be passed without -p flag as the first argument).
# -t : optional analysis tag. Can be used to distinguish different runs (e.g. files). Analysis output will be inside ${chip}/${tag} dir if passed.
# -a : Skip execution of alignment loops, and only run analysis. Used for threshold scans.
# -b : Suppress printing of analysis.pdf file. Used for threshold scans.
# -s : Skip steps. Comma-separated list of steps to skip. Possible values: prealign_tel,align_tel,prealign_dut,align_dut,analysis. Default is empty, meaning no steps are skipped.



date


###########
# Parsing #
###########

# Initialize variables
flag_analysis=false
flag_batch=false
params=""
tag=""


# Allow passing of params via command-line specified .txt file without flags
# Check if the first argument is params file and remove, to allow backwards compatibility
if [[ $# -gt 0 && -f "$1" ]]; then
    params="$1"
    shift  # Remove the file argument from the list so getopts can process the remaining options
fi


# Parse options using getopts
while getopts "abp:t:s:" opt; do
  if [ "$opt" == "a" ]; then
    flag_analysis=true
  elif [ "$opt" == "b" ]; then
    flag_batch=true
  elif [ "$opt" == "p" ]; then
    if [[ -f "$OPTARG" ]]; then
        params="$OPTARG"
    else
        echo "\"${OPTARG}\" does not point to a valid .txt file."
        exit 1
    fi
  elif [ "$opt" == "t" ]; then
    tag="$OPTARG"
  elif [ "$opt" == "s" ]; then
    skip="$OPTARG"
    IFS=',' read -r -a skip_list <<< "$skip"
    echo "Skipping the following steps: ${skip_list[@]}"
  else
    echo "Unknown option: -$opt"
    exit 1
  fi
done



echo "flag_analysis -> ${flag_analysis}"
echo "flag_batch -> ${flag_batch}"
echo "params -> ${params}"
echo "tag -> ${tag}"



# Add trailing slash if tag is passed
tag_w_slash="${tag:+${tag}/}"






##########
# Params #
##########
#These params are overwritten by the params set in the "params" file.

testbeam="SPS202404"
chip="GAP225SQ"
pcb="pcb07"
#HV=()
HV="10"
chillerTemp="" # Default "", for SPS 2024 TB. For DESY 2024 TB use "_t0"
windowSize="" # Default "", for SPS 2024 TB. For DESY 2024 TB use "_winNxN" with N the size of the readout window
momentum=120   #GeV
#(optional, leave blank)
run_number_beam=""
run_number_noise=""
number_of_events=2000
# number_of_events=-1

seedthr_alignment="350"
nbh_alignment="100"
snr_seed_alignment="9"
snr_neighbor_alignment="3"

seedthr_analysis="350"
nbh_analysis="100"
snr_seed_analysis="3"
snr_neighbor_analysis="3"

method_alignment="cluster"
method_analysis="window"

# Only for digitized_window
method_analysis_nbits=4
method_analysis_offset=0
method_analysis_upperBound=10000


niter_prealign_tel=1
niter_align_tel=1
niter_prealign_dut=1
niter_align_dut=1

spatial_cuts=(100 100 75 75 50 50 25 25)

absolute_filepath=""

useNoiseMask="False" # Mask pixels on the DUT to avoid misalignment due to noise. Default is False. Actual cut value used is set in ITS3utils/eudaq/analog_qa_ce65v2.py



# Source params file
if [[ -n "${params}" ]]; then
    source ${params}
else 
    echo "No params .txt file passed. Running with script defaults."
fi





## Below we just define the associative array from "copy_tb_files.sh" to check that chip and pcb match... 
declare -A chips
chips["pcb08"]="GAP225SQ"
chips["pcb02"]="GAP18SQ"
chips["pcb19"]="GAP15SQ"
chips["pcb05"]="GAP225HSQ"
chips["pcb03"]="GAP18HSQ"
chips["pcb18"]="STD225SQ"
chips["pcb23"]="STD18SQ"
chips["pcb06"]="STD15SQ"
chips["pcb07"]="GAP225SQ"
chips["pcb10"]="GAP225SQ"
if [ ! ${chips["${pcb}"]} == ${chip} ]; then 
    echo "CHIP-PCB mismatch. Please check params."
    exit
fi

## Allow calling from a steering script also
if [ "${1:0:3}" == "pcb" ]; then
    pcb=$1
    chip=${chips["${pcb}"]}
fi


## Extract number of pixels to read in x and y
pattern='_win([0-9]+)x([0-9]+)'
if [[ $windowSize =~ $pattern ]]; then
    # Extract the numbers into variables
    nx="${BASH_REMATCH[1]}" # Extract the first captured group
    ny="${BASH_REMATCH[2]}" # Extract the second captured group

    echo "Using window size of ..."
    echo "nx: $nx"
    echo "ny: $ny"

    ## Replacing window size in CE65RawEvent2StdEventConverter class and recompile
    sed -i "s/X_MX_SIZE = 48/X_MX_SIZE = $nx/" /opt/eudaq2/user/ITS3/module/src/CE65RawEvent2StdEventConverter.cc
    sed -i "s/Y_MX_SIZE = 24/Y_MX_SIZE = $ny/" /opt/eudaq2/user/ITS3/module/src/CE65RawEvent2StdEventConverter.cc
    cd /opt/eudaq2/build/
    cmake ..
    make install
    cd -
else
    #echo "Window size not defined, use full window of NX=48 and NY=24. Continuing!"
    nx=48
    ny=24
fi


## We start by checking for the ITS3utils dir
its3_utils_path=`find . -type d -name "ITS3utils"`
if [ -n "$its3_utils_path" ]; then
    its3_utils_path=`realpath $its3_utils_path`
    echo "Using ITS3utils path: ${its3_utils_path}"
else 
    echo "Cannot find dir \"ITS3utils\". Please make sure it is visible from within \"`pwd`\"."
    exit
fi



## Find beam+noise files
if [ ! -n "${run_number_beam}" ]; then
    datafile_beam=`ls -1S ${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run[0-9]*_[0-9]*.raw | head -1`
else
    datafile_beam=`ls -1S ${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}.raw | head -1`
fi
if [ ! -n "${datafile_beam}" ]; then
    echo "Failed to find file(s) : \"${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run[0-9]*_[0-9]*.raw \". Have you ran \"copy_tb_files.sh\" already?"
    exit
fi
datafile_beam=`echo "${datafile_beam}" | sed "s/.*\/\([a-zA-Z0-9_.]*$\)/\1/"`
run_number_beam=`echo "${datafile_beam}" | sed "s/.*run\([0-9]*_[0-9]*\)\.raw/\1/g"`

if [ ! -n "${run_number_noise}" ]; then
    datafile_noise=`ls -1S ${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_noise${windowSize}_run[0-9]*_[0-9]*.raw | head -1`
else
    datafile_noise=`ls -1S ${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_noise${windowSize}_run${run_number_noise}.raw | head -1`
fi
if [ ! -n "${datafile_noise}" ]; then
    echo "Failed to find file(s) : \"${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_noise${windowSize}_run[0-9]*_[0-9]*.raw \". Have you ran \"copy_tb_files.sh\" already?"
    exit
fi
datafile_noise=`echo "${datafile_noise}" | sed "s/.*\/\([a-zA-Z0-9_.]*$\)/\1/"`
run_number_noise=`echo "${datafile_noise}" | sed "s/.*run\([0-9]*_[0-9]*\)\.raw/\1/g"`





#########
# MKDIR #
#########

cd "${its3_utils_path}/${testbeam}"
dirs=( config geometry masks qa output data )
for dir in ${dirs[@]}; do

    if [ ! -d "${dir}/${chip}/${tag}" ]; then 
        mkdir -p "${dir}/${chip}/${tag}"
    fi

    if [ "${dir}" == "masks" ]; then 
        for i in {0..5}; do 
           touch masks/${chip}/${tag_w_slash}ref-plane${i}_HV${HV}.txt 
       done
    fi
done 


testbeam_alphabetic=`echo "${testbeam}" | egrep -o "^[A-Z]+"`




# Now we copy over the files and use `sed` to edit them
## By convention the prototype for each of the copies will be in the parent directory of the class (e.g. masks/ref-plane0.txt)



#######################
# Define source files #
#######################
geo_source="geometry/${testbeam_alphabetic}-GAP18SQ_HV10.geo" 
prealign_source="config/prealign_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf" 
align_source="config/align_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf" 
prealign_dut_source="config/prealign_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf" 
align_dut_source="config/align_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf" 
analysis_source="config/analysis_${testbeam_alphabetic}-GAP18SQ_HV10.conf"

# # check tag passed through params file matches command line tag
# ptag=$(echo `dirname "${params}"` | cut -d'/' -f5)
# if [ ! ${ptag} = ${tag} ]; then 
#     echo "Tag mismatch. Please match tags passed in command line and params file."
# fi

# redefine source files if they have been passed
if [ -e $its3_utils_path/../`dirname "${params}"`/${testbeam_alphabetic}-GAP18SQ_HV10.geo ]; then 
    geo_source=$its3_utils_path/../`dirname "${params}"`/${testbeam_alphabetic}-GAP18SQ_HV10.geo 
fi
if [ -e $its3_utils_path/../`dirname "${params}"`/prealign_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf ]; then 
    prealign_source=$its3_utils_path/../`dirname "${params}"`/prealign_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf 
fi
if [ -e $its3_utils_path/../`dirname "${params}"`/align_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf ]; then 
    align_source=$its3_utils_path/../`dirname "${params}"`/align_tel_${testbeam_alphabetic}-GAP18SQ_HV10.conf 
fi
if [ -e $its3_utils_path/../`dirname "${params}"`/prealign_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf ]; then 
    prealign_dut_source=$its3_utils_path/../`dirname "${params}"`/prealign_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf 
fi
if [ -e $its3_utils_path/../`dirname "${params}"`/align_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf ]; then 
    align_dut_source=$its3_utils_path/../`dirname "${params}"`/align_dut_${testbeam_alphabetic}-GAP18SQ_HV10.conf 
fi
if [ -e $its3_utils_path/../`dirname "${params}"`/analysis_${testbeam_alphabetic}-GAP18SQ_HV10.conf ]; then 
    analysis_source=$its3_utils_path/../`dirname "${params}"`/analysis_${testbeam_alphabetic}-GAP18SQ_HV10.conf 
fi

#####################################################
# Check if absolute path is provided in params file #
#####################################################




#################
# Geometry file #
#################
# copy file from prototype
cp ${geo_source} "geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo"
sleep 5 # wait for file to be copied

# If geo_source is default, then we must alter it. Otherwise it is assumed to be correct.
if [ "${geo_source}" == "geometry/${testbeam_alphabetic}-GAP18SQ_HV10.geo" ]; then

    # replace masks into chip subdir
    if [ "${testbeam}" == "DESY202311" ]; then
        sed -i "s#/local/ITS3utils/DESY202311/masks#${its3_utils_path}/${testbeam}/masks/${chip}${tag:+/${tag}}#g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo
    else
        sed -i "s#\.\./\.\./\.\./DESY202311/masks#${its3_utils_path}/${testbeam}/masks/${chip}${tag:+/${tag}}#g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo
    fi

    # add hv to mask names
    sed -i "s/\(plane[0-5]\)/\1_HV${HV}/g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo

    # write correct CE65V2 pixel-pitch
    pitch=`echo "${chip}" | egrep -o "[0-9]+"`
    if [ "${pitch}" -gt "100" ]; then
        pitch=`echo "22.5"`
    fi
    sed -i "s/pixel_pitch = 18um, 18um/pixel_pitch = ${pitch}um, ${pitch}um/g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo


    # Note that here we are actually keeping the old noisemap file
    sed -i "s#\.\./qa/DESY-GAP18SQ_HV10-noisemap\.root#${its3_utils_path}/${testbeam}/qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noisemap.root#g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo

    if [ "$useNoiseMask" = "True" ]; then
        sed -i "s#\.\./qa/DESY-GAP18SQ_HV10-noisemap_mask\.txt#${its3_utils_path}/${testbeam}/qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noisemap_mask.txt#g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo
    else
        sed -i "s#\.\./qa/DESY-GAP18SQ_HV10-noisemap_mask\.txt##g" geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo
    fi

    # Check if chip name includes "HSQ" (if it's a chip with staggered layout of pixels). In this case the geometry file needs to be adjusted.
    if [[ "${chip}" == *"HSQ"* ]]; then
        # Complicated way to replace the last occurrence of "coordinates = 'cartesian'" with "coordinates = 'staggered'" in the geometry file
        tac geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo | sed '0,/coordinates = "cartesian"/s//coordinates = "staggered"/' | tac > geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo.tmp
        mv geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo.tmp geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}.geo
    fi
fi




############################
# Prealign-tel config file #
############################
# copy file from prototype
cp ${prealign_source} "config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf"
sleep 5 # wait for file to be copied


# update detectors_file(s) file name
# sed -i "s/geometry\/DESY-GAP18SQ_HV10/..\/..\/..\/ament_tests\/geometry\/${chip}\/${tag}\/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag}/prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#\.\./geometry/DESY-GAP18SQ_HV10#${its3_utils_path}/${testbeam}/geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update output file name
#sed -i "s/prealignment/fox\/prealignment/g" config/${chip}/prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#prealignment#${chip}/${tag_w_slash}prealign#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update file name (should only apply to .root at this point)
sed -i "s/DESY-GAP18SQ_HV10/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set number_of_events
sed -i "s/number_of_events.*$/number_of_events = ${number_of_events}/g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# replace inputfilename
if [ -n "${absolute_filepath}" ]; then
    # sed w/ abs filepath
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${absolute_filepath}#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi


#########################
# Align-tel config file #
#########################
# copy file from prototype
cp ${align_source} "config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf"
sleep 5 # wait for file to be copied

# update detectors_file(s) file name
# sed -i "s/geometry\/DESY-GAP18SQ_HV10/..\/..\/..\/ament_tests\/geometry\/${chip}\/${tag}\/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag}/align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#\.\./geometry/DESY-GAP18SQ_HV10#${its3_utils_path}/${testbeam}/geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update output file name
sed -i "s#alignment#${chip}/${tag_w_slash}align#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update file name (should only apply to .root at this point)

sed -i "s/DESY-GAP18SQ_HV10/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set number_of_events
sed -i "s/number_of_events.*$/number_of_events = ${number_of_events}/g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# replace inputfilename
if [ -n "${absolute_filepath}" ]; then
    # sed w/ abs filepath
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${absolute_filepath}#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi

# set momentum
sed -i "s/momentum=4GeV/momentum=${momentum}GeV/g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf




############################
# Prealign-dut config file #
############################
# copy file from prototype
cp ${prealign_dut_source} "config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf"
sleep 5 # wait for file to be copied

# update detectors_file(s) file name
# sed -i "s/geometry\/DESY-GAP18SQ_HV10/..\/..\/..\/ament_tests\/geometry\/${chip}\/${tag}\/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag}/prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#\.\./geometry/DESY-GAP18SQ_HV10#${its3_utils_path}/${testbeam}/geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update output file name
sed -i "s#prealignment#${chip}/${tag_w_slash}prealign#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update file name (should only apply to .root at this point)
sed -i "s/DESY-GAP18SQ_HV10/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf


# set number_of_events
sed -i "s/number_of_events.*$/number_of_events = ${number_of_events}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# replace inputfilename
if [ -n "${absolute_filepath}" ]; then
    # sed w/ abs filepath
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${absolute_filepath}#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi

# set threshold_seed
sed -i "s/threshold_seed.*$/threshold_seed = ${seedthr_alignment}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set threshold_neighbor
sed -i "s/threshold_neighbor.*$/threshold_neighbor = ${nbh_alignment}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_seed
sed -i "s/thresholdSNR_seed.*$/thresholdSNR_seed = ${snr_seed_alignment}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_neighbor
sed -i "s/thresholdSNR_neighbor.*$/thresholdSNR_neighbor = ${snr_neighbor_alignment}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set method
sed -i "s/^method=cluster.*$/method = ${method_alignment}/g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf


#########################
# Align-dut config file #
#########################
# copy file from prototype
cp ${align_dut_source} "config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf"
sleep 5 # wait for file to be copied

# update detectors_file(s) file name
# sed -i "s/geometry\/DESY-GAP18SQ_HV10/..\/..\/..\/ament_tests\/geometry\/${chip}\/${tag}\/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag}/align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#\.\./geometry/DESY-GAP18SQ_HV10#${its3_utils_path}/${testbeam}/geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update output file name
sed -i "s#alignment#${chip}/${tag_w_slash}align#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update file name (should only apply to .root at this point)
sed -i "s/DESY-GAP18SQ_HV10/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set number_of_events
sed -i "s/number_of_events.*$/number_of_events = ${number_of_events}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# replace inputfilename
if [ -n "${absolute_filepath}" ]; then
    # sed w/ abs filepath
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${absolute_filepath}#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi

# set momentum
sed -i "s/momentum=4GeV/momentum=${momentum}GeV/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set threshold_seed
sed -i "s/threshold_seed.*$/threshold_seed = ${seedthr_alignment}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set threshold_neighbor
sed -i "s/threshold_neighbor.*$/threshold_neighbor = ${nbh_alignment}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_seed
sed -i "s/thresholdSNR_seed.*$/thresholdSNR_seed = ${snr_seed_alignment}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_neighbor
sed -i "s/thresholdSNR_neighbor.*$/thresholdSNR_neighbor = ${snr_neighbor_alignment}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf


# set method
sed -i "s/^method=cluster.*$/method = ${method_alignment}/g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf



#########################
# Analysis config file #
#########################
# copy file from prototype
cp ${analysis_source} "config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf"
sleep 5 # wait for file to be copied

# update firstly histogram name
# sed -i "s/analysis_DESY-GAP18SQ_HV10_482100624_231128100629_seedthr200_nbh50_snr3_cluster\.root/${its3_utils_path}\/${testbeam}\/output\/${chip}\/${tag}\/analysis_${testbeam_alphabetic}-${chip}_${run_number_beam}_seedthr${seedthr_analysis}_nbh${nbh_analysis}_snr${snr_seed_analysis}_${method_analysis}.root/g" config/${chip}/${tag}/analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
sed -i "s#analysis_DESY-GAP18SQ_HV10_482100624_231128100629_seedthr200_nbh50_snr3_cluster\.root#${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_${run_number_beam}_seedthr${seedthr_analysis}_nbh${nbh_analysis}_snr${snr_seed_analysis}_${method_analysis}.root#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# update detectors_file(s) file name
sed -i "s#\.\./geometry/DESY-GAP18SQ_HV10#${its3_utils_path}/${testbeam}/geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf



# update file name (should only apply to .root at this point)
sed -i "s/DESY-GAP18SQ_HV10/${testbeam_alphabetic}-${chip}_HV${HV}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set number_of_events
sed -i "s/number_of_events.*$/number_of_events = ${number_of_events}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# replace inputfilename
# sed -i "s/data\/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw/..\/..\/data\/${chip}\/${tag}\/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw/g" config/${chip}/${tag}/analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
# replace inputfilename
if [ -n "${absolute_filepath}" ]; then
    # sed w/ abs filepath
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${absolute_filepath}#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s#\.\./data/ce65v2_pcb02_hv10_beam_run482100624_231128100629\.raw#${its3_utils_path}/${testbeam}/data/${chip}/ce65v2_${pcb}_hv${HV}${chillerTemp}_beam${windowSize}_run${run_number_beam}\.raw#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi

# set momentum
sed -i "s/momentum=4GeV/momentum=${momentum}GeV/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set threshold_seed
sed -i "s/threshold_seed.*$/threshold_seed = ${seedthr_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set threshold_neighbor
sed -i "s/threshold_neighbor.*$/threshold_neighbor = ${nbh_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_seed
sed -i "s/thresholdSNR_seed.*$/thresholdSNR_seed = ${snr_seed_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf

# set thresholdSNR_neighbor
sed -i "s/thresholdSNR_neighbor.*$/thresholdSNR_neighbor = ${snr_neighbor_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf


# set method
# if [ ${method_analysis} == "digitized_window" ]; then
if [[ "${method_analysis}" == "digitized_window" || "${method_analysis}" == "digitized_cluster" ]]; then
    sed -i "s/^method=cluster.*$/method=${method_analysis}\nmethod_nbits=${method_analysis_nbits}\nmethod_offset=${method_analysis_offset}\nmethod_upperBound=${method_analysis_upperBound}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
else
    sed -i "s/^method=cluster.*$/method=${method_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
fi


# set method
sed -i "s/^spatial_cut_abs=.*$/spatial_cut_abs=${spatial_cut_abs_analysis}/g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf



if ! $flag_analysis; then


    ############
    # Noisemap #
    ############

    ## Only needs to be run once per analysis
    ## At the moment multiple chips with same name but different PCBs will not trigger separate noise files. Be careful!

    echo -e "\n\n\n\033[1;95mStarting DUMP\033[0m"


    if [[ ! -f "qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noise-qa.root" ]]; then
        ../eudaq/CE65V2Dump.py data/${chip}/${datafile_noise} -o qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noise --qa --nx ${nx} --ny ${ny}
    fi

    if [[ ! -f "qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noisemap.root" ]]; then
        ../eudaq/analog_qa_ce65v2.py qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noise-qa.root -o qa/${chip}/${testbeam_alphabetic}-${chip}_HV${HV}-noisemap
    fi


    
    if [[ " ${skip_list[@]} " =~ " prealign_tel " ]]; then
        echo "Skipping prealign_tel!"
    else    
        ####################
        # Prealignment-tel #
        ####################
        
        echo -e "\n\n\n\033[1;95m############################################################################\033[0m"
        echo -e "\033[1;95m# execution : corry -c config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf #\033[0m"
        echo -e "\033[1;95m############################################################################\033[0m\n\n\n\033[0m"
        
        i=1
        while [ $i -le ${niter_prealign_tel} ]; do 
            cp config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sleep 5 # wait for file to be copied
            sed -i "s#detectors_file_updated = \(.*\)\.conf#detectors_file_updated = \1_iter${i}.conf#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sed -i "s#histogram_file\(.*\)\.root#histogram_file\1_iter${i}.root#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            if [ ${i} -gt 1 ]; then 
                sed -i "s#detectors_file \(.*\)\.geo#detectors_file \1_prealigned_tel_iter$((i-1)).conf#g" config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            corry -c config/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            # ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag}/prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.root --noisy-freq 0.95
            i=$((i+1))
        done 
        ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag_w_slash}prealign_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${niter_prealign_tel}.root --noisy-freq 0.95
    fi
    

    if [[ " ${skip_list[@]} " =~ " align_tel " ]]; then
        echo "Skipping align_tel!"
    else    
        #################
        # Alignment-tel #
        #################
        
        echo -e "\n\n\n\033[1;95m#########################################################################\033[0m"
        echo -e "\033[1;95m# execution : corry -c config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf #\033[0m"
        echo -e "\033[1;95m#########################################################################\033[0m\n\n\n"
        i=1
        
        
        
        if [ "${spatial_cut_iterations}" == "True" ]; then
            niter_align_tel=${#spatial_cuts[@]}
        fi
        while [ $i -le ${niter_align_tel} ]; do 
            cp config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}.conf config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sleep 5 # wait for file to be copied
            sed -i "s#detectors_file_updated = \(.*\)\.conf#detectors_file_updated = \1_iter${i}.conf#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sed -i "s#histogram_file\(.*\)\.root#histogram_file\1_iter${i}.root#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            # Iteratively decrease spatial_cut if spatial_cut_iterations variable set to true
            if [ "${spatial_cut_iterations}" == "True" ]; then
                sed -i "s#spatial_cut_abs=.*#spatial_cut_abs=${spatial_cuts[$((i-1))]}um,${spatial_cuts[$((i-1))]}um#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            if [ ${i} -gt 1 ]; then 
                sed -i "s#detectors_file \(.*\)\_prealigned_tel.conf#detectors_file \1_aligned_tel_iter$((i-1)).conf#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            else 
                sed -i "s#detectors_file \(.*\)\.conf#detectors_file \1_iter${niter_prealign_tel}.conf#g" config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            corry -c config/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            # ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag}/align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.root --noisy-freq 0.95
            i=$((i+1))
        done 
        ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag_w_slash}align_tel_${testbeam_alphabetic}-${chip}_HV${HV}_iter${niter_align_tel}.root --noisy-freq 0.95
    fi

    
    if [[ " ${skip_list[@]} " =~ " prealign_dut " ]]; then
        echo "Skipping prealign_dut!"
    else    
        ####################
        # Prealignment-dut #
        ####################
        
        echo -e "\n\n\n\033[1;95m############################################################################\033[0m"
        echo -e "\033[1;95m# execution : corry -c config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf #\033[0m"
        echo -e "\033[1;95m############################################################################\033[0m\n\n\n"
        i=1
        while [ $i -le ${niter_prealign_dut} ]; do 
            cp config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sleep 5 # wait for file to be copied
            sed -i "s#detectors_file_updated = \(.*\)\.conf#detectors_file_updated = \1_iter${i}.conf#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sed -i "s#histogram_file\(.*\)\.root#histogram_file\1_iter${i}.root#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            if [ ${i} -gt 1 ]; then 
                sed -i "s#detectors_file \(.*\)\_aligned_tel.conf#detectors_file \1_prealigned_dut_iter$((i-1)).conf#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            else 
                sed -i "s#detectors_file \(.*\)\.conf#detectors_file \1_iter${niter_align_tel}.conf#g" config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            corry -c config/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            i=$((i+1))
        done 
        
        ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag_w_slash}prealign_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${niter_prealign_dut}.root --noisy-freq 0.95
    fi


    if [[ " ${skip_list[@]} " =~ " align_dut " ]]; then
        echo "Skipping align_dut!"
    else    
        #################
        # Alignment-dut #
        #################
        
        echo -e "\n\n\n\033[1;95m#########################################################################\033[0m"
        echo -e "\033[1;95m# execution : corry -c config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf #\033[0m"
        echo -e "\033[1;95m#########################################################################\033[0m\n\n\n"
        i=1
        if [ "${spatial_cut_iterations}" == "True" ]; then
            niter_align_dut=${#spatial_cuts[@]}
        fi
        while [ $i -le ${niter_align_dut} ]; do 
            cp config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}.conf config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sleep 5 # wait for file to be copied

            sed -i "s#detectors_file_updated = \(.*\)\.conf#detectors_file_updated = \1_iter${i}.conf#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            sed -i "s#histogram_file\(.*\)\.root#histogram_file\1_iter${i}.root#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            if [ "${spatial_cut_iterations}" == "True" ]; then
                sed -i "s#spatial_cut_abs=.*#spatial_cut_abs=${spatial_cuts[$((i-1))]}um,${spatial_cuts[$((i-1))]}um#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            if [ ${i} -gt 1 ]; then 
                sed -i "s#detectors_file \(.*\)\_prealigned_dut.conf#detectors_file \1_aligned_dut_iter$((i-1)).conf#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            else 
                sed -i "s#detectors_file \(.*\)\.conf#detectors_file \1_iter${niter_prealign_dut}.conf#g" config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            fi
            corry -c config/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${i}.conf
            i=$((i+1))
        done 
        
        ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag_w_slash}align_dut_${testbeam_alphabetic}-${chip}_HV${HV}_iter${niter_align_dut}.root --noisy-freq 0.95
    fi
fi


if [[ " ${skip_list[@]} " =~ " analysis " ]]; then
    echo "Skipping analysis!"
else    
    ############
    # Analysis #
    ############
    echo -e "\n\n\n\033[1;95m############################################################\033[0m"
    echo -e "\033[1;95m# corry -c config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf #\033[0m"
    echo -e "\033[1;95m############################################################\033[0m\n\n\n"


    ## Below is only necessary since I implemented the niters hackily...
    sed -i "s#detectors_file \(.*\)\.conf#detectors_file \1_iter${niter_align_dut}.conf#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
    sed -i "s#detectors_file_updated = \(.*\)_aligned_dut_analysed.conf#detectors_file_updated = \1_aligned_dut_iter${niter_align_dut}_analysed.conf#g" config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
    nx_prime=$((nx-1))
    ny_prime=$((ny-1))
    sed -i '/type = "ce65v2"/a\
    roi = [[0,0],[0,'"$ny_prime"'],['"$nx_prime"','"$ny_prime"'],['"$nx_prime"',0]]' geometry/${chip}/${tag_w_slash}${testbeam_alphabetic}-${chip}_HV${HV}_aligned_dut_iter${niter_align_dut}.conf

    corry -c config/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_HV${HV}.conf
    if ! $flag_batch; then
        ../corry/plot_analog_ce65v2.py -f output/${chip}/${tag_w_slash}analysis_${testbeam_alphabetic}-${chip}_${run_number_beam}_seedthr${seedthr_analysis}_nbh${nbh_analysis}_snr${snr_seed_analysis}_${method_analysis}.root
    fi
fi

echo -e "\n\n\n\033[1;95m-FINISHED EXECUTION-\033[0m\n\n\n"


date










