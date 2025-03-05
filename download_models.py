#!/usr/bin/env python3

# Downloads required AI models
# Provides progress indicators
# Handles multiple model types

import os
import sys
import requests
import logging
from pathlib import Path

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

MODELS = {
    'face_detection': {
        'files': {
            'deploy.prototxt.txt': 'https://raw.githubusercontent.com/opencv/opencv/master/samples/dnn/face_detector/deploy.prototxt',
            'res10_300x300_ssd_iter_140000.caffemodel': 'https://raw.githubusercontent.com/opencv/opencv_3rdparty/dnn_samples_face_detector_20170830/res10_300x300_ssd_iter_140000.caffemodel'
        },
        'dir': 'face_detection'
    },
    'yolo': {
        'files': {
            'yolov4-tiny.cfg': 'https://raw.githubusercontent.com/AlexeyAB/darknet/master/cfg/yolov4-tiny.cfg',
            'yolov4-tiny.weights': 'https://github.com/AlexeyAB/darknet/releases/download/darknet_yolo_v4_pre/yolov4-tiny.weights',
            'coco.names': 'https://raw.githubusercontent.com/AlexeyAB/darknet/master/data/coco.names'
        },
        'dir': 'yolo'
    }
}

def download_file(url, filepath):
    """Download a file with progress indicator"""
    response = requests.get(url, stream=True)
    total_size = int(response.headers.get('content-length', 0))
    
    with open(filepath, 'wb') as f:
        if total_size == 0:
            f.write(response.content)
        else:
            downloaded = 0
            for data in response.iter_content(chunk_size=8192):
                downloaded += len(data)
                f.write(data)
                done = int(50 * downloaded / total_size)
                sys.stdout.write(f"\r[{'=' * done}{' ' * (50-done)}] {downloaded}/{total_size} bytes")
                sys.stdout.flush()
    print()

def main():
    models_dir = Path('models')
    models_dir.mkdir(exist_ok=True)
    
    for model_name, model_info in MODELS.items():
        model_dir = models_dir / model_info['dir']
        model_dir.mkdir(exist_ok=True)
        
        logger.info(f"Downloading {model_name} models...")
        for filename, url in model_info['files'].items():
            filepath = model_dir / filename
            if not filepath.exists():
                logger.info(f"Downloading {filename}...")
                try:
                    download_file(url, filepath)
                except Exception as e:
                    logger.error(f"Error downloading {filename}: {str(e)}")
            else:
                logger.info(f"{filename} already exists")

if __name__ == "__main__":
    main()
