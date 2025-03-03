#!/usr/bin/env python3
"""
Enhanced Camera System with AI Features
- High FPS camera access via RTSP
- Advanced face detection with face landmarks
- License plate recognition
- Object detection using YOLO
- Enhanced image quality
- Dataset collection for training
"""

import cv2
import numpy as np
import os
import datetime
import time
import threading
import argparse
import json
import logging
from flask import Flask, Response, render_template_string, request, send_file, jsonify
import queue
import psutil
import gc
import collections
from concurrent.futures import ThreadPoolExecutor
import sys

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Default configuration
DEFAULT_CONFIG = {
    'cameras': [
        {
            'name': 'Camera 5',
            'rtsp_url': 'rtsp://<admin:adminpass@ip>:554/cam/realmonitor?channel=5&subtype=0',
            'recording': True,
            'face_detection': True,
            'license_plate_detection': True,
            'object_detection': True,
            'enhance_quality': True,
            'fps_target': 24,  # Target FPS
            'collect_datasets': True
        }
    ],
    'recording_dir': '/opt/camera-system/recordings',
    'dataset_dir': '/opt/camera-system/datasets',
    'models_dir': '/opt/camera-system/models',
    'recording_segment_minutes': 10,
    'motion_sensitivity': 20,
    'face_detection_confidence': 0.5,
    'face_detection_params': {
        'min_size': (60, 60),
        'scale_factor': 1.1,
        'min_neighbors': 3
    },
    'license_plate_confidence': 0.6,
    'object_detection_confidence': 0.5,
    'enhance_scaling_factor': 1.5,
    'web_port': 8080,
    'max_processing_queue': 10,
    'save_detections': True,
    'frame_sample_rate': 5,
    'performance_mode': 'balanced',
    'jpeg_quality': 90,
    'resize_frames': False,
    'resize_factor': 0.75,
    'cpu_optimization': {
        'max_threads': min(4, (os.cpu_count() or 1)),
        'frame_skip': 2,
        'resize_input': True,
        'input_size': (640, 480),
        'process_timeout': 0.1
    },
    'processing_size': (640, 480),
}

# Global models
FACE_DETECTOR = None
FACE_RECOGNITION = None
LICENSE_PLATE_DETECTOR = None
OBJECT_DETECTOR = None
SR_MODEL = None

# Frame buffer class
class FrameBuffer:
    """Thread-safe frame buffer with automatic dropping of old frames"""
    def __init__(self, maxsize=5):
        self.buffer = collections.deque(maxlen=maxsize)
        self.lock = threading.RLock()
        self.last_frame_time = 0

    def put(self, frame):
        with self.lock:
            self.buffer.append(frame)
            self.last_frame_time = time.time()

    def get(self):
        with self.lock:
            if not self.buffer:
                return None
            return self.buffer[-1].copy()

    def clear(self):
        with self.lock:
            self.buffer.clear()

class EnhancedCameraSystem:
    def __init__(self, config=None):
        self.config = config or DEFAULT_CONFIG
        self.cameras = []
        self.ensure_dirs()
        self.load_models()
        self.app = self._create_flask_app()
        self.memory_monitor = MemoryMonitor(threshold_percent=80)
        self.frame_cache = LRUCache(maxsize=100)
        self.thread_pool = ThreadPoolExecutor(max_workers=self.config['cpu_optimization']['max_threads'])
        self.shutdown_event = threading.Event()
        self.watchdog = ThreadWatchdog(self)
        self.watchdog.start()
        self.camera_locks = [threading.RLock() for _ in range(len(self.config['cameras']))]

        for cam_config in self.config['cameras']:
            self.add_camera(cam_config)

    def ensure_dirs(self):
        dirs = [self.config['recording_dir'], self.config['dataset_dir'], self.config['models_dir']]
        for dir_path in dirs:
            if not os.path.exists(dir_path):
                os.makedirs(dir_path)
        dataset_subdirs = ['faces', 'license_plates', 'objects']
        for subdir in dataset_subdirs:
            path = os.path.join(self.config['dataset_dir'], subdir)
            if not os.path.exists(path):
                os.makedirs(path)
        for cam in self.config['cameras']:
            cam_rec_dir = os.path.join(self.config['recording_dir'], cam['name'].replace(' ', '_'))
            if not os.path.exists(cam_rec_dir):
                os.makedirs(cam_rec_dir)
            for subdir in dataset_subdirs:
                path = os.path.join(self.config['dataset_dir'], subdir, cam['name'].replace(' ', '_'))
                if not os.path.exists(path):
                    os.makedirs(path)

    def load_models(self):
        global FACE_DETECTOR, FACE_RECOGNITION, LICENSE_PLATE_DETECTOR, OBJECT_DETECTOR, SR_MODEL
        logger.info("Loading AI models...")
        try:
            # DNN Face Detection Model
            face_model_path = os.path.join(self.config['models_dir'], 'face_detection_model')
            if not os.path.exists(face_model_path):
                os.makedirs(face_model_path)
            
            face_proto = os.path.join(face_model_path, 'deploy.prototxt.txt')
            face_model = os.path.join(face_model_path, 'res10_300x300_ssd_iter_140000.caffemodel')
            
            if os.path.exists(face_proto) and os.path.exists(face_model):
                logger.info("Loading DNN face detector...")
                FACE_DETECTOR = cv2.dnn.readNetFromCaffe(face_proto, face_model)
                # Test the model with a dummy image
                test_img = np.zeros((300, 300, 3), dtype=np.uint8)
                blob = cv2.dnn.blobFromImage(test_img, 1.0, (300, 300), [104, 117, 123])
                FACE_DETECTOR.setInput(blob)
                _ = FACE_DETECTOR.forward()
                # Set backend and target for better performance
                FACE_DETECTOR.setPreferableBackend(cv2.dnn.DNN_BACKEND_DEFAULT)
                FACE_DETECTOR.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
                logger.info("DNN face detector loaded successfully")
            else:
                # Only attempt to download if models don't exist
                logger.warning("DNN face detection model files not found. You need to download them manually:")
                logger.warning(f"1. deploy.prototxt to: {face_proto}")
                logger.warning(f"2. res10_300x300_ssd_iter_140000.caffemodel to: {face_model}")
                raise Exception("Required DNN model files missing")
        except Exception as e:
            logger.error(f"Error loading DNN face detector: {str(e)}")
            logger.info("Falling back to Haar cascade classifier...")
            try:
                FACE_DETECTOR = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
                if FACE_DETECTOR.empty():
                    raise Exception("Failed to load Haar cascade")
                logger.info("Haar cascade face detector loaded successfully")
            except Exception as e2:
                logger.error(f"Error loading Haar cascade: {str(e2)}")
                logger.warning("Face detection will be disabled")
                FACE_DETECTOR = None

        yolo_path = os.path.join(self.config['models_dir'], 'yolo')
        if not os.path.exists(yolo_path):
            os.makedirs(yolo_path)
        yolo_weights = os.path.join(yolo_path, 'yolov4-tiny.weights')
        yolo_config = os.path.join(yolo_path, 'yolov4-tiny.cfg')
        yolo_classes = os.path.join(yolo_path, 'coco.names')
        if os.path.exists(yolo_weights) and os.path.exists(yolo_config) and os.path.exists(yolo_classes):
            OBJECT_DETECTOR = {
                'net': cv2.dnn.readNetFromDarknet(yolo_config, yolo_weights),
                'classes': open(yolo_classes).read().strip().split('\n')
            }
            layer_names = OBJECT_DETECTOR['net'].getLayerNames()
            OBJECT_DETECTOR['output_layers'] = [layer_names[i - 1] for i in OBJECT_DETECTOR['net'].getUnconnectedOutLayers()]
        else:
            logger.warning("YOLO model files not found. Object detection disabled.")

    def add_camera(self, camera_config):
        camera = {
            'config': camera_config,
            'stream': None,
            'frame': None,
            'original_frame_buffer': FrameBuffer(maxsize=3),
            'processed_frame_buffer': FrameBuffer(maxsize=2),
            'recording_thread': None,
            'processing_thread': None,
            'processing_queue': queue.Queue(maxsize=self.config['max_processing_queue']),
            'frame_counter': 0,
            'fps': 0,
            'last_fps_time': time.time(),
            'last_frame_time': 0,
            'frame_count': 0,
            'detections': {'faces': [], 'license_plates': [], 'objects': []},
            'prev_frame': None,
            'motion_detected': False,
            'writer': None,
            'recording_file': None,
            'recording_start_time': None,
            'datasets': {'faces': 0, 'license_plates': 0, 'objects': 0}
        }
        self.cameras.append(camera)
        thread = threading.Thread(target=self._camera_thread, args=(len(self.cameras) - 1,))
        thread.daemon = True
        thread.start()
        return len(self.cameras) - 1

    def _camera_thread(self, camera_index):
        camera = self.cameras[camera_index]
        config = camera['config']
        backoff = ExponentialBackoff()
        while not self.shutdown_event.is_set():
            try:
                if camera['stream'] is None:
                    camera['stream'] = cv2.VideoCapture(config['rtsp_url'])
                    if not camera['stream'].isOpened():
                        logger.error(f"Failed to connect to camera {config['name']}")
                        time.sleep(backoff.delay())
                        continue
                    logger.info(f"Connected to camera {config['name']}")
                    backoff.reset()
                if config['recording'] and camera['recording_thread'] is None:
                    camera['recording_thread'] = threading.Thread(target=self._recording_thread, args=(camera_index,))
                    camera['recording_thread'].daemon = True
                    camera['recording_thread'].start()
                if camera['processing_thread'] is None:
                    camera['processing_thread'] = threading.Thread(target=self._processing_thread, args=(camera_index,))
                    camera['processing_thread'].daemon = True
                    camera['processing_thread'].start()
                ret, frame = camera['stream'].read()
                if not ret:
                    logger.warning(f"Failed to read frame from {config['name']}")
                    self._handle_camera_error(camera)
                    continue
                camera['frame'] = frame
                camera['last_frame_time'] = time.time()
                camera['frame_counter'] += 1
                camera['frame_count'] += 1
                self._update_fps(camera)
                if camera['frame_count'] % self.config['frame_sample_rate'] == 0:
                    try:
                        if not camera['processing_queue'].full():
                            camera['processing_queue'].put(frame, block=False)
                    except queue.Full:
                        pass
                camera['original_frame_buffer'].put(frame.copy())
                fps_delay = 1.0 / config['fps_target']
                time.sleep(max(0.001, fps_delay))
            except Exception as e:
                logger.error(f"Camera thread error for {config['name']}: {str(e)}")
                self._handle_camera_error(camera)
                time.sleep(backoff.delay())
        if camera['stream'] is not None:
            camera['stream'].release()
            camera['stream'] = None

    def _recording_thread(self, camera_index):
        camera = self.cameras[camera_index]
        config = camera['config']
        segment_seconds = self.config['recording_segment_minutes'] * 60
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        while not self.shutdown_event.is_set():
            try:
                if camera['frame'] is not None:
                    current_time = time.time()
                    if (camera['recording_start_time'] is None or
                            current_time - camera['recording_start_time'] > segment_seconds):
                        if camera['writer'] is not None:
                            camera['writer'].release()
                            camera['writer'] = None
                        timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
                        filename = f"{config['name'].replace(' ', '_')}_{timestamp}.mp4"
                        filepath = os.path.join(self.config['recording_dir'], config['name'].replace(' ', '_'), filename)
                        height, width = camera['frame'].shape[:2]
                        camera['writer'] = cv2.VideoWriter(filepath, fourcc, config['fps_target'], (width, height))
                        camera['recording_file'] = filepath
                        camera['recording_start_time'] = current_time
                        logger.info(f"Started new recording segment: {filepath}")
                    if camera['writer'] is not None:
                        frame_to_write = camera['processed_frame_buffer'].get()
                        if frame_to_write is not None:
                            camera['writer'].write(frame_to_write)
                    time.sleep(0.01)
            except Exception as e:
                logger.error(f"Error in recording thread: {str(e)}")
                time.sleep(1)

    def _processing_thread(self, camera_index):
        camera = self.cameras[camera_index]
        config = camera['config']
        while not self.shutdown_event.is_set():
            try:
                frame = camera['processing_queue'].get(timeout=self.config['cpu_optimization']['process_timeout'])
                if self.memory_monitor.is_critical():
                    camera['processing_queue'].task_done()
                    time.sleep(0.1)
                    continue
                processed_frame = self._process_frame(frame, camera)
                if processed_frame is not None:
                    camera['processed_frame_buffer'].put(processed_frame)
                camera['processing_queue'].task_done()
            except queue.Empty:
                continue
            except Exception as e:
                logger.error(f"Processing error: {str(e)}")
                time.sleep(0.1)

    def get_frame(self, camera_index, frame_type='processed'):
        camera = self.cameras[camera_index]
        frame = camera['processed_frame_buffer'].get() if frame_type == 'processed' else camera['original_frame_buffer'].get()
        if frame is None:
            frame = camera['frame']
        if frame is None:
            blank = np.zeros((480, 640, 3), np.uint8)
            cv2.putText(blank, "No Frame Available", (160, 240), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
            _, jpeg = cv2.imencode('.jpg', blank)
            return jpeg.tobytes()
        if self.config['resize_frames'] and frame_type == 'processed':
            height, width = frame.shape[:2]
            new_height = int(height * self.config['resize_factor'])
            new_width = int(width * self.config['resize_factor'])
            frame = cv2.resize(frame, (new_width, new_height))
        encode_params = [int(cv2.IMWRITE_JPEG_QUALITY), self.config['jpeg_quality']]
        _, jpeg = cv2.imencode('.jpg', frame, encode_params)
        return jpeg.tobytes()

    def _create_flask_app(self):
        app = Flask(__name__)

        @app.route('/')
        def index():
            html = '''
            <!DOCTYPE html>
            <html>
            <head>
                <title>Enhanced Camera System</title>
                <style>
                    body { font-family: Arial, sans-serif; margin: 0; padding: 20px; }
                    .camera-container { margin-bottom: 40px; }
                    .camera-feeds { display: flex; }
                    .feed-container { margin-right: 20px; }
                    .feed-title { text-align: center; }
                    .camera-feed { width: 640px; }
                    .stats { margin-top: 10px; }
                </style>
                <script>
                    function updateStats() {
                        fetch('/get_stats')
                            .then(response => response.json())
                            .then(data => {
                                data.forEach((camera, index) => {
                                    document.getElementById(`stats_${index}`).innerHTML =
                                        `FPS: ${camera.fps}<br>Motion Detected: ${camera.motion_detected}`;
                                });
                            });
                    }
                    setInterval(updateStats, 1000);
                </script>
            </head>
            <body>
                <h1>Enhanced Camera System</h1>
                {% for i, camera in enumerate(cameras) %}
                <div class="camera-container">
                    <div>{{ camera.config.name }}</div>
                    <div class="camera-feeds">
                        <div class="feed-container">
                            <div class="feed-title">Original Feed</div>
                            <img src="/video/{{ i }}/original" class="camera-feed">
                        </div>
                        <div class="feed-container">
                            <div class="feed-title">Enhanced Feed</div>
                            <img src="/video/{{ i }}/processed" class="camera-feed">
                        </div>
                    </div>
                    <div class="stats" id="stats_{{ i }}">
                        FPS: {{ camera.fps }}<br>Motion Detected: {{ camera.motion_detected }}
                    </div>
                </div>
                {% endfor %}
            </body>
            </html>
            '''
            return render_template_string(html, cameras=self.cameras, enumerate=enumerate)

        @app.route('/video/<int:camera_id>/<frame_type>')
        def video_feed(camera_id, frame_type='processed'):
            if camera_id >= len(self.cameras):
                return "Camera not found", 404
            def generate():
                while True:
                    frame = self.get_frame(camera_id, frame_type)
                    yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')
                    time.sleep(0.03 if frame_type == 'processed' else 0.01)
            return Response(generate(), mimetype='multipart/x-mixed-replace; boundary=frame')

        @app.route('/get_stats')
        def get_stats():
            stats = [{'fps': f"{camera['fps']:.1f}", 'motion_detected': camera['motion_detected']} for camera in self.cameras]
            return jsonify(stats)

        return app

    def run_web_server(self):
        self.app.run(host='0.0.0.0', port=self.config['web_port'], threaded=True)

    def cleanup(self):
        self.shutdown_event.set()
        self.thread_pool.shutdown(wait=True)
        for camera in self.cameras:
            if camera['stream'] is not None:
                camera['stream'].release()
            if camera['writer'] is not None:
                camera['writer'].release()
        self.watchdog.stop()
        gc.collect()

    def _process_frame(self, frame, camera):
        processed_frame = frame.copy()
        detections = {'faces': []}

        if camera['config']['face_detection'] and FACE_DETECTOR is not None:
            try:
                if isinstance(FACE_DETECTOR, cv2.dnn_Net):
                    # Using DNN detector
                    height, width = frame.shape[:2]
                    # Prepare the frame for DNN
                    blob = cv2.dnn.blobFromImage(
                        frame, 1.0, (300, 300),
                        [104, 117, 123],
                        swapRB=False,
                        crop=False
                    )
                    
                    # Detect faces
                    FACE_DETECTOR.setInput(blob)
                    detections_matrix = FACE_DETECTOR.forward()
                    
                    # Process detections
                    for i in range(detections_matrix.shape[2]):
                        confidence = detections_matrix[0, 0, i, 2]
                        if confidence > self.config['face_detection_confidence']:
                            box = detections_matrix[0, 0, i, 3:7] * np.array([width, height, width, height])
                            (startX, startY, endX, endY) = box.astype("int")
                            w = endX - startX
                            h = endY - startY
                            detections['faces'].append((startX, startY, w, h, confidence))
                            logger.debug(f"Face detected with confidence {confidence:.2f}")
                else:
                    # Using Haar cascade detector
                    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                    faces = FACE_DETECTOR.detectMultiScale(
                        gray,
                        scaleFactor=self.config['face_detection_params']['scale_factor'],
                        minNeighbors=self.config['face_detection_params']['min_neighbors'],
                        minSize=self.config['face_detection_params']['min_size']
                    )
                    for (x, y, w, h) in faces:
                        detections['faces'].append((x, y, w, h, 1.0))
                        
            except Exception as e:
                logger.error(f"Error in face detection: {str(e)}")

            # Draw bounding boxes and confidence scores
            for (x, y, w, h, conf) in detections['faces']:
                cv2.rectangle(processed_frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
                cv2.putText(processed_frame, f"Face: {conf:.2f}", (x, y - 10),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)

            # Save detected faces for dataset collection (if enabled)
            if camera['config']['collect_datasets'] and self.config['save_detections']:
                timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                for i, (x, y, w, h, conf) in enumerate(detections['faces']):
                    face_img = frame[y:y+h, x:x+w]
                    face_filepath = os.path.join(
                        self.config['dataset_dir'],
                        'faces',
                        camera['config']['name'].replace(' ', '_'),
                        f'face_{timestamp}_{i}.jpg'
                    )
                    os.makedirs(os.path.dirname(face_filepath), exist_ok=True)
                    cv2.imwrite(face_filepath, face_img)
                    camera['datasets']['faces'] = camera['datasets'].get('faces', 0) + 1

        return processed_frame

    def _update_fps(self, camera):
        current_time = time.time()
        time_diff = current_time - camera['last_fps_time']
        if time_diff >= 1.0:
            camera['fps'] = round(camera['frame_counter'] / time_diff, 1)
            camera['frame_counter'] = 0
            camera['last_fps_time'] = current_time

    def _handle_camera_error(self, camera):
        if camera['stream'] is not None:
            camera['stream'].release()
            camera['stream'] = None
        camera['frame'] = None

class MemoryMonitor:
    def __init__(self, threshold_percent=80):
        self.threshold = threshold_percent
        self._process = psutil.Process()
        self.cpu_percent = 0
        self.last_check = 0

    def update_stats(self):
        current_time = time.time()
        if current_time - self.last_check >= 1.0:
            self.cpu_percent = self._process.cpu_percent()
            self.last_check = current_time

    def is_critical(self):
        self.update_stats()
        return psutil.virtual_memory().percent > self.threshold or self.cpu_percent > 300

class ExponentialBackoff:
    def __init__(self, initial=1, maximum=60):
        self.initial = initial
        self.maximum = maximum
        self.current = initial

    def delay(self):
        delay = min(self.current, self.maximum)
        self.current = min(self.current * 2, self.maximum)
        return delay

    def reset(self):
        self.current = self.initial

class LRUCache:
    def __init__(self, maxsize=100):
        self.cache = collections.OrderedDict()
        self.maxsize = maxsize

    def get(self, key):
        if key not in self.cache:
            return None
        self.cache.move_to_end(key)
        return self.cache[key]

    def put(self, key, value):
        if key in self.cache:
            self.cache.move_to_end(key)
        self.cache[key] = value
        if len(self.cache) > self.maxsize:
            self.cache.popitem(last=False)

    def clear(self):
        self.cache.clear()

class ThreadWatchdog:
    def __init__(self, camera_system):
        self.camera_system = camera_system
        self.running = True
        self.thread = threading.Thread(target=self._watchdog_thread)
        self.thread.daemon = True

    def start(self):
        self.thread.start()

    def stop(self):
        self.running = False
        if self.thread.is_alive():
            self.thread.join(timeout=2)

    def _watchdog_thread(self):
        while self.running and not self.camera_system.shutdown_event.is_set():
            for i, camera in enumerate(self.camera_system.cameras):
                if camera['last_frame_time'] > 0 and time.time() - camera['last_frame_time'] > 10:
                    logger.warning(f"Camera {camera['config']['name']} stalled, reconnecting...")
                    if camera['stream'] is not None:
                        camera['stream'].release()
                        camera['stream'] = None
                if camera['processing_thread'] is None or not camera['processing_thread'].is_alive():
                    camera['processing_thread'] = threading.Thread(target=self.camera_system._processing_thread, args=(i,))
                    camera['processing_thread'].daemon = True
                    camera['processing_thread'].start()
            time.sleep(5)

def main():
    parser = argparse.ArgumentParser(description='Enhanced Camera System with AI Features')
    parser.add_argument('--config', type=str, help='Path to configuration file')
    parser.add_argument('--port', type=int, help='Web server port')
    args = parser.parse_args()

    config = DEFAULT_CONFIG.copy()
    if args.config and os.path.exists(args.config):
        with open(args.config, 'r') as f:
            config.update(json.load(f))
    if args.port:
        config['web_port'] = args.port

    system = EnhancedCameraSystem(config)
    try:
        system.run_web_server()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    finally:
        system.cleanup()

if __name__ == "__main__":
    cv2.setNumThreads(min(8, (os.cpu_count() or 1)))
    main()