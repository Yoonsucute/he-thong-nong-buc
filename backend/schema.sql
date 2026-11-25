-- MySQL 8+. Giữ nguyên dữ liệu đã có.
CREATE DATABASE IF NOT EXISTS iot_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE iot_db;
CREATE TABLE IF NOT EXISTS sensor_logs (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(100) NOT NULL,
    temperature DOUBLE NOT NULL,
    humidity DOUBLE NOT NULL,
    heat_index DOUBLE NULL,
    latitude DOUBLE NULL,
    longitude DOUBLE NULL,
    location_source VARCHAR(16) NULL DEFAULT 'unknown',
    location_updated_at DATETIME NULL,
    gps_valid BOOLEAN NULL,
    satellites TINYINT UNSIGNED NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_sensor_device_time (device_id, created_at, id)
);
CREATE TABLE IF NOT EXISTS devices (
    device_id VARCHAR(100) PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    latitude DOUBLE NULL,
    longitude DOUBLE NULL,
    location_source VARCHAR(16) NULL DEFAULT 'unknown',
    location_updated_at DATETIME NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    location_pending BOOLEAN NOT NULL DEFAULT TRUE,
    gps_valid BOOLEAN NULL,
    satellites TINYINT UNSIGNED NULL,
    gps_reported_at DATETIME NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
-- app.ensure_schema adds missing columns on existing installations.
-- Existing rows keep their location provenance and have NULL GPS metadata.
INSERT IGNORE INTO devices (device_id,name,latitude,longitude,location_source,location_updated_at)
SELECT s.device_id,s.device_id,s.latitude,s.longitude,COALESCE(s.location_source,'unknown'),s.location_updated_at FROM sensor_logs s
INNER JOIN (SELECT device_id,MAX(id) id FROM sensor_logs GROUP BY device_id) latest ON s.id=latest.id;
