#!/bin/bash

cd $path_cwd

REQ_FILE="$func_dir/requirements.txt"

if [ -f "$REQ_FILE" ]; then
    $runtime -m venv lambda_env_$func_dir
    source lambda_env_$func_dir/bin/activate
    pip install -r $REQ_FILE
    
    deactivate

    rm -rf $func_dir-pkg
    mkdir $func_dir-pkg
    cp -r $func_dir/* $func_dir-pkg

    for dir in `cat $REQ_FILE | cut -d"=" -f1`; do
      cp -r lambda_env_$func_dir/lib/$runtime/site-packages/$dir* $func_dir-pkg
    done

    rm -rf lambda_env_$func_dir
else
    rm -rf $func_dir-pkg
    mkdir $func_dir-pkg
    cp -r $func_dir/* $func_dir-pkg
fi