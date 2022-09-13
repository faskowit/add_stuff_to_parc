#!/bin/bash

usage() 
{
cat <<usagetext

USAGE: ${0} 
        -d          inputFSDir 
        -o          outputDir
        -f          fsVersion (5p3 or 6p0 or 7p1)
        -s          flag to enable parc stats 
usagetext
}

main() 
{

start=`date +%s`
################################################################################

# Check the number of arguments. If none are passed, print help and exit.
NUMARGS=$#
if [ $NUMARGS -lt 3 ]; then
	echo "Not enough args"
	usage &>2 
	exit 1
fi

# read in args
while getopts ":T:O:W:P:D:L:h" OPTION
do
     case $OPTION in
		T)
			INPUT_T1=$OPTARG
			;;
		O)
			OUT_DIR=$OPTARG
            ;;  
        W)
            WORK_DIR=$OPTARG
            ;;
        P)
            IN_PARC+=($OPTARG)
            ;;
        D)
            DATA_DIR=$OPTARG
            ;;   
        L)
            TIAN_LEVEL=$OPTARG
            ;;   
		h) 
			usage >&2
            exit 0
      		;;
        :)
            echo "Invalid option: $OPTARG requires an argument" 1>&2
            ;;
		?) # getopts issues an error message
			usage >&2
            exit 1
      		;;
     esac
done

shift "$((OPTIND-1))" # Shift off the options and optional

################################################################################
# check some inputs

if [[ ! -e $INPUT_T1 ]] ; then
	echo "input T1 ($INPUT_T1) does not exist" >&2
	exit 1
fi

for ppp in "${IN_PARC[@]}"; do
    if [[ ! -e $ppp ]] ; then
		echo "input parc ($ppp) does not exist" >&2
		exit 1
	fi
done

mkdir -p $OUT_DIR || { echo "could not make output dir. error" ; exit 1 ; }

if [[ -z $WORK_DIR ]] ; then # if workdir not set
	WORK_DIR=$OUT_DIR 
fi

if [[ -z $DATA_DIR ]] && [[ -z $TIANDIR ]] ; then
	echo "need to have data dir or TIANDIR set"
fi
# potentially set data dir to Tian dir
[[ -z $DATA_DIR ]] && DATA_DIR=$TIANDIR

# defualt TIAN_LEVEL
[[ -z $TIAN_LEVEL ]] && TIAN_LEVEL=S2

case $TIAN_LEVEL in
	S1)
		subcortAtlas=${DATA_DIR}/3T/Subcortex-Only/Tian_Subcortex_S1_3T_1mm.nii.gz
		subcNodes=16
		;;
	S2) 
		subcortAtlas=${DATA_DIR}/3T/Subcortex-Only/Tian_Subcortex_S2_3T_1mm.nii.gz
		subcNodes=32
		;;
	S3)
		subcortAtlas=${DATA_DIR}/3T/Subcortex-Only/Tian_Subcortex_S3_3T_1mm.nii.gz
		subcNodes=50
		;;
	S4)
		subcortAtlas=${DATA_DIR}/3T/Subcortex-Only/Tian_Subcortex_S4_3T_1mm.nii.gz
		subcNodes=54
		;;
	*)
		echo "error. $TIAN_LEVEL not option. must be S1, S2, S3, or S4"
		exit 1
		;;
esac

if [[ ! -e $subcortAtlas ]] ; then
	subcortAtlas2=$( ${subcortAtlas} | sed 's,/3T/Subcortex-Only/,/,')
	if [[ -e ${subcortAtlas2} ]] ; then 
		subcortAtlas=$subcortAtlas2
	else
		echo "expected $subcortAtlas or $subcortAtlas2 to exist, it does not. error"
		exit 1
	fi
fi

if [[ -z $ANTSPATH ]] || [[ -z $FSLDIR ]] ; then
	echo "need to have both ANTSPATH and FSLDIR set. exiting"
	exit 1
fi

################################################################################
# register T1 to MNI

mniAtlas=${FSLDIR}/data/standard/MNI152_T1_1mm_brain.nii.gz
fixedImage=${INPUT_T1}

ANTS_LINEAR_CONVERGENCE="[ 1000x500x250x100,1e-6,5 ]"
ANTS_LINEAR_METRIC_PARAMS="1,32,Regular,0.25"
stage1="-m MI[ ${fixedImage},${mniAtlas},${ANTS_LINEAR_METRIC_PARAMS} ] -c ${ANTS_LINEAR_CONVERGENCE} -t Rigid[ 0.1 ] -f 8x4x2x1 -s 4x2x1x0"
stage2="-m MI[ ${fixedImage},${mniAtlas},${ANTS_LINEAR_METRIC_PARAMS} ] -c ${ANTS_LINEAR_CONVERGENCE} -t Affine[ 0.1 ] -f 8x4x2x1 -s 4x2x1x0"

SYNCONVERGENCE="[ 100x70x50x0,1e-6,10 ]"
SYNSHRINKFACTORS="8x4x2x1"
SYNSMOOTHINGSIGMAS="3x2x1x0vox"
# SYNMETRIC="CC[ ${fixedImage} , ${mniAtlas} , 1 , 4 ]"
SYNMETRIC="CC[ ${fixedImage} , ${mniAtlas} , 1 , 2 ]"

################################################################################

cmd="${ANTSPATH}/antsRegistration -d 3 -v 1 \
        --output [ ${WORK_DIR}/antsreg , ${WORK_DIR}/antsreg_brain.nii.gz ] \
        --write-composite-transform 1 \
        -r [${fixedImage},${mniAtlas},0] \
        ${stage1} ${stage2} \
        \
        --transform SyN[0.25,3.0,0.75] \
        --metric ${SYNMETRIC} \
        --convergence ${SYNCONVERGENCE} \
        --shrink-factors ${SYNSHRINKFACTORS} \
        --smoothing-sigmas ${SYNSMOOTHINGSIGMAS} \
        --use-histogram-matching 1 \
	"
echo $cmd #state the command
[[ ! -e ${WORK_DIR}/antsregComposite.h5 ]] && eval $cmd 

################################################################################
# now warp the subcortical

cmd="${ANTSPATH}/antsApplyTransforms -d 3 -e 0 \
        -i ${subcortAtlas} \
        -r ${fixedImage} \
        -o ${WORK_DIR}/tian${TIAN_LEVEL}_2_t1.nii.gz \
        -n NearestNeighbor \
        -t $(ls ${WORK_DIR}/antsregComposite.h5 ) \
	"
echo $cmd #state the command
[[ ! -e ${WORK_DIR}/tian${TIAN_LEVEL}_2_t1.nii.gz ]] && eval $cmd #execute 

################################################################################
# add to parc

for ppp in "${IN_PARC[@]}"; do
    echo "working on: $ppp"

    currImg=$ppp
    outImgBase=$(echo $(basename $ppp) | sed 's,.nii.gz,,' )

    # get the max value here
    maxCortical=$(fslstats $ppp -R | awk '{print int($2)}')
    echo "max cortical is: $maxCortical"

    # add max cortical to the subc image, then take max with existing atlas to 
    # get the new parcellation
    cmd="fslmaths ${WORK_DIR}/tian${TIAN_LEVEL}_2_t1.nii.gz \
    		-add ${maxCortical} -thr $((maxCortical + 1)) \
    		-max $ppp \
    		${OUT_DIR}/${outImgBase}_tian${TIAN_LEVEL}.nii.gz \
    		"
    echo $cmd
    eval $cmd

done

################################################################################
end=`date +%s`
runtime=$((end-start))
echo "runtime: $runtime"
################################################################################

} # main 

# run main with input args from shell scrip call
main "$@"
