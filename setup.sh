#!/bin/bash

# Update package lists
sudo apt-get update

# Install system dependencies
sudo apt-get install -y \
    python3-pip \
    python3-opencv \
    ffmpeg \
    libsm6 \
    libxext6 \
    libgstreamer1.0-0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer1.0-dev \
    libavcodec-extra \
    libavformat-dev \
    libswscale-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev

# Create directories
sudo mkdir -p /opt/camera-system/{recordings,datasets,models}
sudo chmod -R 777 /opt/camera-system

# Install Python dependencies for root user
sudo pip3 install -r requirements.txt

# Download AI models
cd /opt/camera-system/models

# Download face detection model
sudo mkdir -p face_detection_model
cd face_detection_model
sudo wget https://raw.githubusercontent.com/opencv/opencv/master/samples/dnn/face_detector/deploy.prototxt
sudo wget https://raw.githubusercontent.com/opencv/opencv_3rdparty/dnn_samples_face_detector_20170830/res10_300x300_ssd_iter_140000.caffemodel

# Download YOLO model
cd ../
sudo mkdir -p yolo
cd yolo
sudo wget https://github.com/AlexeyAB/darknet/releases/download/darknet_yolo_v4_pre/yolov4-tiny.weights
sudo wget https://raw.githubusercontent.com/AlexeyAB/darknet/master/cfg/yolov4-tiny.cfg
sudo wget https://raw.githubusercontent.com/AlexeyAB/darknet/master/data/coco.names

# Download license plate cascade
cd ../
sudo wget https://raw.githubusercontent.com/opencv/opencv/master/data/haarcascades/haarcascade_russian_plate_number.xml -O lp_cascade.xml

# Set proper permissions
sudo chown -R root:root /opt/camera-system 