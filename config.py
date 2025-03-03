
{
    "cameras": [
        {
            "name": "Camera 1",
            "rtsp_url": "rtsp://<admin:adminpass@ip>:554/cam/realmonitor?channel=5&subtype=0",
            "recording": true,
            "face_detection": true,
            "object_detection": true,
            "collect_datasets": true,
            "fps_target": 24
        }
    ],
    "recording_dir": "recordings",
    "dataset_dir": "datasets",
    "models_dir": "models",
    "recording_segment_minutes": 10,
    "face_detection_confidence": 0.5,
    "object_detection_confidence": 0.5,
    "web_port": 8080,
    "auth_username": "admin",
    "auth_password": "adminpass",
    "processing_size": [640, 480],
    "enhance_image": true
}
