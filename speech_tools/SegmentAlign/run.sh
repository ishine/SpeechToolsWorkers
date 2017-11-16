#!/bin/bash

set -e -o pipefail

beam=20
retry_beam=300

echo "$0 $@"  # Print the command line for logging
. parse_options.sh || exit 1;

if [ $# -ne 3 ]; then
  echo "Usage: ./run.sh <input-wav> <input-txt> <proj-name>"
  echo "Creates a folder <proj-name> and aligns the WAV/TXT inside it."
  echo "Result is saved in <proj-name>/output.ctm"
  exit 1
fi

wav_file=`readlink -f $1`
txt_file=`readlink -f $2`
proj_name=`readlink -f $3`

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ ! -e $proj_name ] ; then
    mkdir -p ${proj_name}
fi

mkdir ${proj_name}/data

echo input $wav_file > ${proj_name}/data/wav.scp
echo input `cat $txt_file` > ${proj_name}/data/text
echo input spk > ${proj_name}/data/utt2spk
echo spk input > ${proj_name}/data/spk2utt

cd ${proj_name}

ln -s ${SCRIPT_DIR}/model/path.sh
ln -s ${SCRIPT_DIR}/model/tri3b_mmi
ln -s ${SCRIPT_DIR}/model/local_utils
ln -s ${SCRIPT_DIR}/model/phonetisaurus


. path.sh

ln -s $KALDI_ROOT/egs/wsj/s5/utils
ln -s $KALDI_ROOT/egs/wsj/s5/steps
ln -s $KALDI_ROOT/egs/wsj/s5/conf
ln -s $KALDI_ROOT/egs/wsj/s5/local

#feature extraction
./steps/make_mfcc.sh --nj 1 data
./steps/compute_cmvn_stats.sh data
#data preparation
./local_utils/prepare_dict.sh data dict
./utils/prepare_lang.sh dict "<unk>" tmp lang
#segmentation and cleaning
./steps/cleanup/clean_and_segment_data.sh --nj 1 data lang tri3b_mmi cleanup cleaned
echo "input input 1" > cleaned/reco2file_and_channel
#alignemnt of clean data
./steps/align_fmllr.sh --nj 1 --beam ${beam} --retry-beam ${retry_beam} cleaned lang tri3b_mmi ali_clean
#adaptation to clean data
./steps/train_map.sh cleaned lang ali_clean adapted
#resegmentation using adapted model
./steps/cleanup/clean_and_segment_data.sh --nj 1 data lang adapted cleanup_ad cleaned_ad
echo "input input 1" > cleaned_ad/reco2file_and_channel
#alignemnt of adapted clean data
./steps/align_fmllr.sh --nj 1 --beam ${beam} --retry-beam ${retry_beam} cleaned_ad lang adapted ali_ad
#make CTM in the ali folder
./steps/get_train_ctm.sh cleaned_ad lang ali_ad
python local_utils/fix_ctm.py ali_ad/ctm ali_ad/ctm.fixed
./local_utils/get_phoneme_ctm.sh cleaned_ad lang ali_ad
python local_utils/fix_ctm.py ali_ad/phonectm ali_ad/phonectm.fixed
#get missing segments
sort -k3n ali_ad/ctm -o ali_ad/ctm.sorted
./local_utils/get_deleted_seg.sh cleanup_ad lang data ali_ad/ctm.sorted deleted
#force realign missing segments
./steps/align_fmllr.sh --nj 1 --beam ${beam} --retry-beam ${retry_beam} deleted lang adapted ali_deleted
echo "input input 1" > deleted/reco2file_and_channel
./steps/get_train_ctm.sh deleted lang ali_deleted
python local_utils/fix_ctm.py ali_deleted/ctm ali_deleted/ctm.fixed
./local_utils/get_phoneme_ctm.sh deleted lang ali_deleted
python local_utils/fix_ctm.py ali_deleted/phonectm ali_deleted/phonectm.fixed
#merge CTMs
cat ali_ad/ctm.fixed ali_deleted/ctm.fixed > ctm.combined
python local_utils/fix_ctm.py ctm.combined  words.ctm
cat ali_ad/phonectm.fixed ali_deleted/phonectm.fixed > phonectm.combined
python local_utils/fix_ctm.py phonectm.combined phonemes.ctm

awk '$0="@"$0' phonemes.ctm | cat words.ctm - | sort -r -k3n > output.ctm

python local_utils/convert_ctm_tg.py words.ctm phonemes.ctm segmentation.TextGrid

echo Finished generating alignment...
