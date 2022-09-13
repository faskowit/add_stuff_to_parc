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

DO_SUIT=0
# read in args
while getopts ":T:O:W:P:D:L:A:hS" OPTION
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
        S)
            DO_SUIT=1
            ;; 
        A) 
			IN_TRANSF=${OPTARG}
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

if [[ -z $DATA_DIR ]] ; then
	echo "if data dir is not set, we are expecting this script to have the \
		  variables TIANDIR and/or SUITDIR exported to it"
fi
# # potentially set data dir to Tian dir
# [[ -z $DATA_DIR ]] && DATA_DIR=$TIANDIR
[[ ! -z $DATA_DIR ]] && TIANDIR=$DATA_DIR
[[ ! -z $DATA_DIR ]] && SUITDIR=$DATA_DIR

# defualt TIAN_LEVEL
[[ -z $TIAN_LEVEL ]] && TIAN_LEVEL=S2

case $TIAN_LEVEL in
	S1)
		subcortAtlas=${TIANDIR}/3T/Subcortex-Only/Tian_Subcortex_S1_3T_1mm.nii.gz
		subcNodes=16
		;;
	S2) 
		subcortAtlas=${TIANDIR}/3T/Subcortex-Only/Tian_Subcortex_S2_3T_1mm.nii.gz
		subcNodes=32
		;;
	S3)
		subcortAtlas=${TIANDIR}/3T/Subcortex-Only/Tian_Subcortex_S3_3T_1mm.nii.gz
		subcNodes=50
		;;
	S4)
		subcortAtlas=${TIANDIR}/3T/Subcortex-Only/Tian_Subcortex_S4_3T_1mm.nii.gz
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

if [[ $DO_SUIT -eq 1 ]] ; then # make sure we can read the atlas
	cereAtlas=${SUITDIR}/Diedrichsen_2009/atl-Anatom_space-MNI_dseg.nii
	cereAtlas2=${SUITDIR}/atl-Anatom_space-MNI_dseg.nii
	if [[ -e $cereAtlas ]] ; then
		echo "found suit atlas: $cereAtlas"
	elif [[ -e cereAtlas2 ]] ; then
		cereAtlas=$cereAtlas2
		echo "found suit atlas: $cereAtlas"
	else
		echo "expected $cereAtlas or $cereAtlas2 to exist, it does not. error"
		exit 1
	fi
fi

if [[ ! -z $IN_TRANSF ]] ; then
	if [[ ! -e $IN_TRANSF ]] ; then
		echo "input transform provided does not exist. exiting"
		exit 1
	fi
fi

################################################################################
# register T1 to MNI

mniAtlas=${FSLDIR}/data/standard/MNI152_T1_1mm_brain.nii.gz
fixedImage=${INPUT_T1}

ANTS_LINEAR_CONVERGENCE="[ 1000x500x250x100,1e-6,5 ]"
ANTS_LINEAR_METRIC_PARAMS="1,32,Regular,0.25"
stage1="-m MI[ ${fixedImage},${mniAtlas},${ANTS_LINEAR_METRIC_PARAMS} ] -c ${ANTS_LINEAR_CONVERGENCE} -t Rigid[ 0.1 ] -f 8x4x2x1 -s 4x2x1x0"
stage2="-m MI[ ${fixedImage},${mniAtlas},${ANTS_LINEAR_METRIC_PARAMS} ] -c ${ANTS_LINEAR_CONVERGENCE} -t Affine[ 0.1 ] -f 8x4x2x1 -s 4x2x1x0"

SYNCONVERGENCE="[ 100x75x50x0,1e-6,10 ]"
SYNSHRINKFACTORS="8x4x2x1"
SYNSMOOTHINGSIGMAS="3x2x1x0vox"
# SYNMETRIC="CC[ ${fixedImage} , ${mniAtlas} , 1 , 4 ]"
SYNMETRIC="CC[ ${fixedImage} , ${mniAtlas} , 1 , 2 ]"
# SYNMETRIC="MI[ ${fixedImage} , ${mniAtlas} ]"

################################################################################

if [[ -z $IN_TRANSF ]] ; then # if transform not provided, make it

	cmd="${ANTSPATH}/antsRegistration -d 3 -v 1 \
	        --output [ ${WORK_DIR}/antsreg , ${WORK_DIR}/antsreg_brain.nii.gz ] \
	        --write-composite-transform 1 \
	        -r [${fixedImage},${mniAtlas},0] \
	        ${stage1} ${stage2} \
	        \
	        --transform SyN[0.25,3.0,0.25] \
	        --metric ${SYNMETRIC} \
	        --convergence ${SYNCONVERGENCE} \
	        --shrink-factors ${SYNSHRINKFACTORS} \
	        --smoothing-sigmas ${SYNSMOOTHINGSIGMAS} \
	        --use-histogram-matching 1 \
		"
	echo $cmd #state the command
	[[ ! -e ${WORK_DIR}/antsregComposite.h5 ]] && eval $cmd 

	# immediately delete inverse
	rm ${WORK_DIR}/antsregInverseComposite.h5

	applyTrans=${WORK_DIR}/antsregComposite.h5
else
	echo "using supplied transform"
	applyTrans=$IN_TRANSF
fi

################################################################################
# now warp the subcortical

cmd="${ANTSPATH}/antsApplyTransforms -d 3 -e 0 \
        -i ${subcortAtlas} \
        -r ${fixedImage} \
        -o ${WORK_DIR}/tian${TIAN_LEVEL}_2_t1.nii.gz \
        -n NearestNeighbor \
        -t ${applyTrans} \
	"
echo $cmd #state the command
[[ ! -e ${WORK_DIR}/tian${TIAN_LEVEL}_2_t1.nii.gz ]] && eval $cmd #execute 

if [[ DO_SUIT -eq 1 ]] ; then
	cmd="${ANTSPATH}/antsApplyTransforms -d 3 -e 0 \
	        -i ${cereAtlas} \
	        -r ${fixedImage} \
	        -o ${WORK_DIR}/suit_2_t1.nii.gz \
	        -n NearestNeighbor \
	        -t ${applyTrans} \
		"
	echo $cmd #state the command
	[[ ! -e ${WORK_DIR}/suit_2_t1.nii.gz ]] && eval $cmd #execute 
fi

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

	if [[ DO_SUIT -eq 1 ]] ; then

		newMax=$(( maxCortical + subcNodes ))
	    cmd="fslmaths ${WORK_DIR}/suit_2_t1.nii.gz \
	    		-add ${newMax} -thr $((newMax + 1)) \
	    		-max ${OUT_DIR}/${outImgBase}_tian${TIAN_LEVEL}.nii.gz \
	    		${OUT_DIR}/${outImgBase}_tian${TIAN_LEVEL}_suit.nii.gz \
	    		"
	    echo $cmd
	    eval $cmd		

	    ls ${OUT_DIR}/${outImgBase}_tian${TIAN_LEVEL}.nii.gz && \
	    	rm ${OUT_DIR}/${outImgBase}_tian${TIAN_LEVEL}.nii.gz

	fi

done

################################################################################
end=`date +%s`
runtime=$((end-start))
echo "runtime: $runtime"
################################################################################

} # main 

# run main with input args from shell scrip call
main "$@"
