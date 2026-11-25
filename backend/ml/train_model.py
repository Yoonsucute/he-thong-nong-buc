"""Huấn luyện và đánh giá mô hình LSTM dự báo chỉ số nóng bức 5 giờ tới.

Hỗ trợ đọc dữ liệu thực tế từ MySQL (bảng sensor_logs), file CSV, hoặc
dữ liệu giả lập (chỉ khi truyền tường minh `--source synthetic`).
Chia tập train/test theo thứ tự thời gian (không rò rỉ dữ liệu) và tính
đầy đủ 3 chỉ số đánh giá MAE, RMSE, R² theo đề cương đồ án.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
import sys

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.preprocessing import MinMaxScaler

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(BASE_DIR, "heat_index_lstm.keras")
SCALER_PATH = os.path.join(BASE_DIR, "scaler.pkl")
METRICS_PATH = os.path.join(BASE_DIR, "evaluation_metrics.json")

LOOKBACK = 12
FORECAST_STEPS = 5
LOCAL_TZ = timezone(timedelta(hours=7))

try:
    from .ml_service import calculate_heat_index
except ImportError:
    sys.path.insert(0, BASE_DIR)
    from ml_service import calculate_heat_index


def get_db_config():
    return {
        "host": os.getenv("DB_HOST", "127.0.0.1"),
        "port": int(os.getenv("DB_PORT", "3307")),
        "user": os.getenv("DB_USER", "root"),
        "password": os.getenv("DB_PASSWORD", "root"),
        "database": os.getenv("DB_NAME", "iot_db"),
        "charset": "utf8mb4",
        "connect_timeout": 5,
        "read_timeout": 15,
    }


def load_from_mysql(device_id=None):
    import pymysql

    config = get_db_config()
    connection = pymysql.connect(**config, cursorclass=pymysql.cursors.DictCursor)
    try:
        with connection.cursor() as cursor:
            if device_id:
                cursor.execute(
                    """SELECT created_at, temperature, humidity, heat_index
                       FROM sensor_logs WHERE device_id=%s
                       ORDER BY created_at ASC, id ASC""",
                    (device_id,),
                )
            else:
                cursor.execute(
                    """SELECT created_at, temperature, humidity, heat_index
                       FROM sensor_logs
                       ORDER BY created_at ASC, id ASC"""
                )
            rows = cursor.fetchall()
    finally:
        connection.close()
    if not rows:
        raise ValueError("Bảng sensor_logs trong MySQL chưa có dữ liệu.")
    return pd.DataFrame(rows)


def load_from_csv(csv_path):
    if not csv_path or not os.path.isfile(csv_path):
        raise ValueError(f"Không tìm thấy tệp CSV: {csv_path}")
    return pd.read_csv(csv_path)


def generate_synthetic_hourly(days=30, seed=42):
    """Chỉ dùng để kiểm thử quy trình khi truyền `--source synthetic`."""
    rng = np.random.default_rng(seed)
    total_hours = 24 * days
    start = datetime.now(LOCAL_TZ).replace(minute=0, second=0, microsecond=0) - timedelta(hours=total_hours)
    timestamps = [start + timedelta(hours=i) for i in range(total_hours)]
    hours_of_day = np.arange(total_hours) % 24
    diurnal = 31.0 + 5.5 * np.sin((hours_of_day - 8) * 2 * np.pi / 24.0)
    seasonal = 1.2 * np.sin(np.linspace(0, 4 * np.pi, total_hours))
    noise = rng.normal(0, 0.9, total_hours)
    heat_index = np.round(diurnal + seasonal + noise, 1)
    return pd.DataFrame({"created_at": timestamps, "heat_index": heat_index})


def clean_and_resample_hourly(df, max_interp_gap=2):
    """Làm sạch dữ liệu đo và gom trung bình theo từng giờ."""
    frame = df.copy()
    if "created_at" not in frame.columns:
        raise ValueError("Dữ liệu phải có cột created_at.")
    frame["created_at"] = pd.to_datetime(frame["created_at"], errors="coerce")
    frame = frame.dropna(subset=["created_at"]).sort_values("created_at")

    if "temperature" in frame.columns:
        frame["temperature"] = pd.to_numeric(frame["temperature"], errors="coerce")
        frame = frame[frame["temperature"].isna() | frame["temperature"].between(-20, 80)]
    if "humidity" in frame.columns:
        frame["humidity"] = pd.to_numeric(frame["humidity"], errors="coerce")
        frame = frame[frame["humidity"].isna() | frame["humidity"].between(0, 100)]

    if "heat_index" in frame.columns:
        frame["heat_index"] = pd.to_numeric(frame["heat_index"], errors="coerce")
    else:
        frame["heat_index"] = np.nan

    if {"temperature", "humidity"}.issubset(frame.columns):
        missing_hi = frame["heat_index"].isna() & frame["temperature"].notna() & frame["humidity"].notna()
        if missing_hi.any():
            frame.loc[missing_hi, "heat_index"] = [
                calculate_heat_index(float(t), float(h))
                for t, h in zip(frame.loc[missing_hi, "temperature"], frame.loc[missing_hi, "humidity"])
            ]

    frame = frame.dropna(subset=["heat_index"])
    frame = frame[frame["heat_index"].between(-20, 80)]
    if frame.empty:
        raise ValueError("Không còn bản ghi hợp lệ sau khi làm sạch dữ liệu.")

    hourly = frame.set_index("created_at")["heat_index"].resample("1h").mean()
    if max_interp_gap > 0:
        hourly = hourly.interpolate(method="linear", limit=max_interp_gap, limit_area="inside")
    return hourly


def build_contiguous_windows(hourly_series, lookback=LOOKBACK, forecast_steps=FORECAST_STEPS):
    """Tạo các cửa sổ trượt (12 giờ vào -> 5 giờ ra) chỉ trên chuỗi giờ liên tục."""
    values = hourly_series.to_numpy(dtype=np.float64)
    total_window = lookback + forecast_steps
    X_list, y_list = [], []
    run_start = 0

    for idx in range(len(values) + 1):
        is_end = idx == len(values) or not math.isfinite(float(values[idx]))
        if is_end:
            segment = values[run_start:idx]
            if len(segment) >= total_window:
                for offset in range(len(segment) - total_window + 1):
                    X_list.append(segment[offset : offset + lookback])
                    y_list.append(segment[offset + lookback : offset + total_window])
            run_start = idx + 1

    if not X_list:
        raise ValueError(
            f"Không đủ chuỗi giờ liên tục (cần ít nhất {total_window} giờ liên tiếp không bị gián đoạn)."
        )
    return np.asarray(X_list, dtype=np.float32), np.asarray(y_list, dtype=np.float32)


def evaluate_predictions(y_true, y_pred):
    """Tính MAE, RMSE và R² tổng thể và theo từng giờ dự báo (+1h..+5h)."""
    y_true = np.asarray(y_true, dtype=np.float64)
    y_pred = np.asarray(y_pred, dtype=np.float64)

    overall_mae = float(mean_absolute_error(y_true.reshape(-1), y_pred.reshape(-1)))
    overall_rmse = float(math.sqrt(mean_squared_error(y_true.reshape(-1), y_pred.reshape(-1))))
    overall_r2 = float(r2_score(y_true.reshape(-1), y_pred.reshape(-1)))

    per_horizon = []
    for step in range(y_true.shape[1]):
        true_col = y_true[:, step]
        pred_col = y_pred[:, step]
        per_horizon.append({
            "horizon_hour": step + 1,
            "mae": round(float(mean_absolute_error(true_col, pred_col)), 4),
            "rmse": round(float(math.sqrt(mean_squared_error(true_col, pred_col))), 4),
            "r2": round(float(r2_score(true_col, pred_col)), 4),
        })

    return {
        "overall": {
            "mae": round(overall_mae, 4),
            "rmse": round(overall_rmse, 4),
            "r2": round(overall_r2, 4),
        },
        "per_horizon": per_horizon,
    }


def train_and_evaluate(
    source="mysql",
    device_id=None,
    csv_path=None,
    epochs=40,
    batch_size=16,
    test_ratio=0.2,
    min_windows=20,
    synthetic_days=30,
):
    if source == "mysql":
        raw_df = load_from_mysql(device_id=device_id)
    elif source == "csv":
        raw_df = load_from_csv(csv_path)
    elif source == "synthetic":
        raw_df = generate_synthetic_hourly(days=synthetic_days)
    else:
        raise ValueError("source phải là 'mysql', 'csv' hoặc 'synthetic'.")

    hourly = clean_and_resample_hourly(raw_df)
    X_raw, y_raw = build_contiguous_windows(hourly, LOOKBACK, FORECAST_STEPS)
    if len(X_raw) < min_windows:
        raise ValueError(
            f"Chỉ tạo được {len(X_raw)} mẫu huấn luyện (cần tối thiểu {min_windows} mẫu). "
            "Hãy thu thập thêm dữ liệu thực tế từ ESP32 hoặc dùng `--source synthetic` để kiểm thử."
        )

    split_idx = max(1, int(len(X_raw) * (1.0 - test_ratio)))
    if split_idx >= len(X_raw):
        split_idx = len(X_raw) - 1

    X_train_raw, X_test_raw = X_raw[:split_idx], X_raw[split_idx:]
    y_train_raw, y_test_raw = y_raw[:split_idx], y_raw[split_idx:]

    # Fit MinMaxScaler CHỈ trên tập huấn luyện để tránh rò rỉ dữ liệu (data leakage).
    scaler = MinMaxScaler(feature_range=(0, 1))
    train_flat = np.concatenate([X_train_raw.reshape(-1), y_train_raw.reshape(-1)]).reshape(-1, 1)
    scaler.fit(train_flat)

    X_train = scaler.transform(X_train_raw.reshape(-1, 1)).reshape(X_train_raw.shape[0], LOOKBACK, 1)
    y_train = scaler.transform(y_train_raw.reshape(-1, 1)).reshape(y_train_raw.shape[0], FORECAST_STEPS)
    X_test = scaler.transform(X_test_raw.reshape(-1, 1)).reshape(X_test_raw.shape[0], LOOKBACK, 1)

    import keras
    from keras.callbacks import EarlyStopping
    from keras.layers import Dense, Dropout, Input, LSTM
    from keras.models import Sequential

    model = Sequential([
        Input(shape=(LOOKBACK, 1)),
        LSTM(units=64, return_sequences=True),
        Dropout(0.2),
        LSTM(units=32, return_sequences=False),
        Dropout(0.2),
        Dense(units=16, activation="relu"),
        Dense(units=FORECAST_STEPS),
    ])
    model.compile(optimizer="adam", loss="mean_squared_error", metrics=["mae"])

    callbacks = [EarlyStopping(monitor="val_loss", patience=6, restore_best_weights=True)]
    print(f"Đang huấn luyện mô hình LSTM ({len(X_train)} mẫu train, {len(X_test)} mẫu test)...")
    model.fit(
        X_train,
        y_train,
        validation_split=0.15 if len(X_train) >= 20 else 0.0,
        epochs=epochs,
        batch_size=batch_size,
        shuffle=False,
        callbacks=callbacks if len(X_train) >= 20 else [],
        verbose=1,
    )

    y_pred_scaled = model.predict(X_test, verbose=0)
    y_pred = scaler.inverse_transform(y_pred_scaled.reshape(-1, 1)).reshape(y_test_raw.shape)

    metrics = evaluate_predictions(y_test_raw, y_pred)
    joblib.dump(scaler, SCALER_PATH)
    model.save(MODEL_PATH)

    report = {
        "trained_at": datetime.now(LOCAL_TZ).isoformat(timespec="seconds"),
        "source": source,
        "device_id": device_id,
        "lookback_hours": LOOKBACK,
        "forecast_hours": FORECAST_STEPS,
        "total_valid_hours": int(hourly.notna().sum()),
        "train_samples": int(len(X_train)),
        "test_samples": int(len(X_test)),
        "metrics": metrics,
    }
    with open(METRICS_PATH, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)

    print("\n===== KẾT QUẢ ĐÁNH GIÁ MÔ HÌNH LSTM (TẬP KIỂM TRA) =====")
    print(f"Nguồn dữ liệu : {source}" + (f" ({device_id})" if device_id else ""))
    print(f"Số mẫu        : {len(X_train)} train / {len(X_test)} test")
    print(f"MAE tổng thể  : {metrics['overall']['mae']:.4f} °C")
    print(f"RMSE tổng thể : {metrics['overall']['rmse']:.4f} °C")
    print(f"R² tổng thể   : {metrics['overall']['r2']:.4f}")
    print("\nChi tiết theo từng giờ dự báo:")
    for item in metrics["per_horizon"]:
        print(
            f"  +{item['horizon_hour']}h -> MAE: {item['mae']:.4f} °C | "
            f"RMSE: {item['rmse']:.4f} °C | R²: {item['r2']:.4f}"
        )
    print(f"\n-> Đã lưu mô hình : {MODEL_PATH}")
    print(f"-> Đã lưu scaler  : {SCALER_PATH}")
    print(f"-> Đã lưu báo cáo : {METRICS_PATH}")
    return report


def parse_args():
    parser = argparse.ArgumentParser(description="Huấn luyện và đánh giá mô hình LSTM HeatWatch.")
    parser.add_argument("--source", choices=["mysql", "csv", "synthetic"], default="mysql",
                        help="Nguồn dữ liệu huấn luyện (mặc định: mysql).")
    parser.add_argument("--device-id", default=None, help="Lọc theo mã thiết bị (vd: ESP32_01).")
    parser.add_argument("--csv-path", default=None, help="Đường dẫn tệp CSV khi dùng --source csv.")
    parser.add_argument("--epochs", type=int, default=40, help="Số epoch tối đa (mặc định: 40).")
    parser.add_argument("--batch-size", type=int, default=16, help="Kích thước batch (mặc định: 16).")
    parser.add_argument("--test-ratio", type=float, default=0.2, help="Tỷ lệ tập test (mặc định: 0.2).")
    parser.add_argument("--synthetic-days", type=int, default=30, help="Số ngày dữ liệu mẫu khi dùng --source synthetic.")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    train_and_evaluate(
        source=args.source,
        device_id=args.device_id,
        csv_path=args.csv_path,
        epochs=args.epochs,
        batch_size=args.batch_size,
        test_ratio=args.test_ratio,
        synthetic_days=args.synthetic_days,
    )
