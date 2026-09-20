#include <Arduino.h>

/*
 * SpatialForge (ChromaGrip) — ESP32 Firmware (merged with verified wiring)
 * -------------------------------------------------------------------------
 * This combines your hardware verification test (MPU-6050 + HC-SR04 +
 * TCS3200) with the WiFi/WebSocket layer that streams data to the iPhone
 * app. Pin numbers below match YOUR physical wiring exactly.
 *
 * PINS (as wired on your breadboard)
 *   MPU-6050  -> I2C   SDA = GPIO8,  SCL = GPIO9
 *   HC-SR04   -> TRIG  = GPIO4,      ECHO = GPIO5 (through your voltage divider)
 *   TCS3200   -> S2    = GPIO10,     S3   = GPIO11,  OUT = GPIO12
 *                S0 and S1 are assumed wired DIRECTLY to your 3.3V rail
 *                (not to the ESP32) for 100% output scaling. If that's not
 *                how you wired it, color readings will be unreliable —
 *                tell me and I'll adjust this file.
 *
 * LIBRARIES (Arduino Library Manager)
 *   - Adafruit MPU6050
 *   - Adafruit Unified Sensor
 *   - WebSockets by Markus Sattler (Links2004/arduinoWebSockets)
 *
 * WIFI
 *   ESP32 hosts an AP called "SpatialPuck". iOS app connects to
 *   ws://192.168.4.1:81/ — this part is unchanged from before, so your
 *   existing Swift app needs NO changes.
 */

#include <WiFi.h>
#include <WebSocketsServer.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

// ---------- Pin Assignments (matches your verified wiring) ----------
#define SDA_PIN 8
#define SCL_PIN 9
#define TRIG_PIN 4
#define ECHO_PIN 5
#define S2_PIN 10
#define S3_PIN 11
#define OUT_PIN 12

// ---------- WiFi AP Config ----------
const char* AP_SSID = "SpatialPuck";
const char* AP_PASS = "spatial123"; // 8+ chars for WPA2; use "" for open network

WebSocketsServer webSocket = WebSocketsServer(81);

// ---------- MPU-6050 ----------
Adafruit_MPU6050 mpu;

// ---------- IMU Complementary Filter State ----------
float pitch = 0.0f;
float roll = 0.0f;
unsigned long lastIMUMicros = 0;
const float ALPHA = 0.96f;
const float DEADBAND_DEG = 1.0f;

// ---------- Distance Sensor State ----------
float distCM = 3.0f;
const float DIST_MIN = 3.0f;
const float DIST_MAX = 20.0f;
const float DIST_SMOOTH = 0.25f;

// ---------- Color Sensor State ----------
// TCS3200 outputs a pulse whose WIDTH is inversely related to color
// intensity: a SHORT pulse means a bright/strong color, a LONG pulse
// (or a timeout) means dark/no surface detected. These raw microsecond
// values need normalizing into a 0-255 range and INVERTING (short=high).
uint8_t latchedR = 128, latchedG = 128, latchedB = 128;
const unsigned long PULSE_TIMEOUT_US = 25000;
// Tune these two after watching real readings on Serial: RAW_MIN should be
// roughly the shortest pulse you see pointed at something bright white,
// RAW_MAX roughly the longest pulse before it's basically "nothing there."
const int RAW_MIN = 12;
const int RAW_MAX = 450;
const unsigned long CONTACT_MAX_PULSE = 200;

unsigned long lastStreamMillis = 0;
const unsigned long STREAM_INTERVAL_MS = 22; // ~45 Hz

void setupWiFiAP() {
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  Serial.print("AP started. IP address: ");
  Serial.println(WiFi.softAPIP());
}

void onWebSocketEvent(uint8_t clientNum, WStype_t type, uint8_t* payload, size_t length) {
  if (type == WStype_CONNECTED) {
    Serial.printf("Client %u connected\n", clientNum);
  } else if (type == WStype_DISCONNECTED) {
    Serial.printf("Client %u disconnected\n", clientNum);
  }
}

// ---------- Distance ----------
float readDistanceCM() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  long duration = pulseIn(ECHO_PIN, HIGH, 30000);
  if (duration == 0) return -1.0f;
  return duration * 0.034f / 2.0f;
}

void updateDistance() {
  float raw = readDistanceCM();
  if (raw < 0) return; // keep last good value on timeout
  float clamped = constrain(raw, DIST_MIN, DIST_MAX);
  distCM = distCM + DIST_SMOOTH * (clamped - distCM);
}

// ---------- IMU ----------
void updateIMU() {
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  unsigned long now = micros();
  float dt = (lastIMUMicros == 0) ? 0.01f : (now - lastIMUMicros) / 1000000.0f;
  lastIMUMicros = now;

  float accelPitch = atan2(-a.acceleration.x,
                            sqrt(a.acceleration.y * a.acceleration.y +
                                 a.acceleration.z * a.acceleration.z)) * 180.0f / PI;
  float accelRoll  = atan2(a.acceleration.y, a.acceleration.z) * 180.0f / PI;

  float gyroPitchRate = g.gyro.y * 180.0f / PI;
  float gyroRollRate  = g.gyro.x * 180.0f / PI;

  float newPitch = ALPHA * (pitch + gyroPitchRate * dt) + (1.0f - ALPHA) * accelPitch;
  float newRoll  = ALPHA * (roll  + gyroRollRate  * dt) + (1.0f - ALPHA) * accelRoll;

  if (fabs(newPitch - pitch) > DEADBAND_DEG || fabs(newRoll - roll) > DEADBAND_DEG) {
    pitch = newPitch;
    roll = newRoll;
  } else {
    pitch = ALPHA * pitch + (1.0f - ALPHA) * accelPitch;
    roll  = ALPHA * roll  + (1.0f - ALPHA) * accelRoll;
  }
}

// ---------- Color ----------
// Reads one color channel by selecting the filter (s2State, s3State) and
// timing the resulting pulse. Returns the RAW pulse width in microseconds
// (NOT yet a 0-255 value) — see normalizeColor() for that conversion.
unsigned long readColorRaw(int s2State, int s3State) {
  digitalWrite(S2_PIN, s2State);
  digitalWrite(S3_PIN, s3State);
  return pulseIn(OUT_PIN, LOW, PULSE_TIMEOUT_US);
}

// Converts a raw pulse width into a 0-255 brightness value, INVERTED
// (short pulse = strong color = high number) and clamped to RAW_MIN/RAW_MAX.
uint8_t normalizeColor(unsigned long raw) {
  if (raw == 0) return 0; // timed out — treat as "no signal" (dark)
  long clamped = constrain((long)raw, RAW_MIN, RAW_MAX);
  long inverted = map(clamped, RAW_MIN, RAW_MAX, 255, 0);
  return (uint8_t)constrain(inverted, 0, 255);
}

void updateColor() {
// Read Clear channel first (S2=HIGH, S3=LOW) to verify a surface is touching
  unsigned long rawClear = readColorRaw(HIGH, LOW);

  // If sensor is in open air, timed out, or no surface is pressed close: keep previous color
  if (rawClear == 0 || rawClear > CONTACT_MAX_PULSE) {
    return;
  }

  unsigned long rawRed   = readColorRaw(LOW, LOW);
  unsigned long rawBlue  = readColorRaw(LOW, HIGH);
  unsigned long rawGreen = readColorRaw(HIGH, HIGH);

  Serial.print("RAW  R:");
  Serial.print(rawRed);
  Serial.print(" G:");
  Serial.print(rawGreen);
  Serial.print(" B:");
  Serial.println(rawBlue);

  latchedR = normalizeColor(rawRed);
  latchedG = normalizeColor(rawGreen);
  latchedB = normalizeColor(rawBlue);
}

void broadcastTelemetry() {
  char json[160];
  snprintf(json, sizeof(json),
    "{\"pitch\":%.2f,\"roll\":%.2f,\"dist\":%.2f,\"r\":%u,\"g\":%u,\"b\":%u}",
    pitch, roll, distCM, latchedR, latchedG, latchedB);
  webSocket.broadcastTXT(json);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  pinMode(S2_PIN, OUTPUT);
  pinMode(S3_PIN, OUTPUT);
  pinMode(OUT_PIN, INPUT);

  Wire.begin(SDA_PIN, SCL_PIN);

  if (!mpu.begin()) {
    Serial.println("MPU6050 not found - check wiring!");
  } else {
    mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    Serial.println("MPU6050 ready.");
  }

  setupWiFiAP();
  webSocket.begin();
  webSocket.onEvent(onWebSocketEvent);

  Serial.println("=== SpatialForge firmware ready, streaming over WebSocket ===");
  lastIMUMicros = 0;
}

void loop() {
  webSocket.loop();

  updateIMU();
  updateDistance();
  updateColor();

  unsigned long now = millis();
  if (now - lastStreamMillis >= STREAM_INTERVAL_MS) {
    lastStreamMillis = now;
    broadcastTelemetry();
  }
}