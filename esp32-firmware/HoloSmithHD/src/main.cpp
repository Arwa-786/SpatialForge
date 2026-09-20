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
#include <Preferences.h>

// ---------- Pin Assignments (matches your verified wiring) ----------
#define SDA_PIN 8
#define SCL_PIN 9
#define TRIG_PIN 4
#define ECHO_PIN 5
#define S0_PIN 6
#define S1_PIN 7
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
// Fallback bounds, used until real per-channel calibration is captured (or if
// it's ever reset). Each color channel's sensor response isn't identical, so
// a single shared min/max is only ever an approximation — see calibration
// below for the precise, per-channel version.
const int RAW_MIN = 12;
const int RAW_MAX = 450;
// Contact/proximity gate on the Clear channel: pulses longer than this are
// treated as "nothing in front of the sensor" and the last latched color is
// kept. Must sit ABOVE the darkest real reading (black, up close, can run
// close to RAW_MAX) so black isn't mistaken for "far away" — that was the
// original bug. Default is a conservative guess; watch the "RAW Clear:"
// Serial print with the sensor on open air vs. on a black surface up close
// and tighten this value to sit cleanly between the two.
const unsigned long CONTACT_MAX_PULSE = 3000;

// ---------- Color Sensor Calibration (per-channel, persisted to flash) ----------
// calMin*: raw pulse width (us) seen for that channel against a bright WHITE
// reference. calMax*: raw pulse width seen against a dark/BLACK reference.
// Trigger from the Arduino Serial Monitor: send 'w' while holding a white
// surface to the sensor, 'k' while holding a black surface, 'r' to reset.
Preferences colorPrefs;
int calMinR = RAW_MIN, calMinG = RAW_MIN, calMinB = RAW_MIN;
int calMaxR = RAW_MAX, calMaxG = RAW_MAX, calMaxB = RAW_MAX;

unsigned long lastStreamMillis = 0;
const unsigned long STREAM_INTERVAL_MS = 22; // ~45 Hz

// Forward declarations — these are defined later in the file (they need
// readColorRaw() etc. above them) but onWebSocketEvent(), defined next,
// needs to call them when the app sends a calibration command.
void calibrateWhitePoint();
void calibrateBlackPoint();
void resetColorCalibration();

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
  } else if (type == WStype_TEXT) {
    // Same calibration commands the Serial Monitor accepts ('w'/'k'/'r'),
    // now reachable from the app's Settings screen over the WebSocket.
    String command = String((char*)payload, length);
    if (command == "calibrate_white") calibrateWhitePoint();
    else if (command == "calibrate_black") calibrateBlackPoint();
    else if (command == "reset_calibration") resetColorCalibration();
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
unsigned long lastIMUDebugMillis = 0;
const unsigned long IMU_DEBUG_INTERVAL_MS = 300; // throttled — this runs every loop() otherwise

void updateIMU() {
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // Raw accel should read ~9.8 on whichever axis currently points against
  // gravity when the puck is held still, and visibly shift as you tilt it.
  // All exactly 0 (or unchanging no matter how you move it) means mpu.begin()
  // likely failed silently at boot — check for "MPU6050 not found" earlier
  // in this same Serial log.
  unsigned long nowMs = millis();
  if (nowMs - lastIMUDebugMillis >= IMU_DEBUG_INTERVAL_MS) {
    lastIMUDebugMillis = nowMs;
    Serial.print("IMU accel(m/s^2) x:");
    Serial.print(a.acceleration.x);
    Serial.print(" y:");
    Serial.print(a.acceleration.y);
    Serial.print(" z:");
    Serial.print(a.acceleration.z);
    Serial.print(" | gyro(rad/s) x:");
    Serial.print(g.gyro.x);
    Serial.print(" y:");
    Serial.print(g.gyro.y);
    Serial.print(" z:");
    Serial.print(g.gyro.z);
    Serial.print(" | pitch:");
    Serial.print(pitch);
    Serial.print(" roll:");
    Serial.println(roll);
  }

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
// (short pulse = strong color = high number) and clamped to that channel's
// own calibrated [channelMin, channelMax] range.
uint8_t normalizeColor(unsigned long raw, int channelMin, int channelMax) {
  if (raw == 0) return 0; // timed out — treat as "no signal" (dark)
  if (channelMax <= channelMin) channelMax = channelMin + 1; // guard bad/uncalibrated data
  long clamped = constrain((long)raw, (long)channelMin, (long)channelMax);
  long inverted = map(clamped, channelMin, channelMax, 255, 0);
  return (uint8_t)constrain(inverted, 0, 255);
}

// ---------- Color Calibration ----------
void loadColorCalibration() {
  colorPrefs.begin("colorcal", true);
  calMinR = colorPrefs.getInt("minR", RAW_MIN);
  calMinG = colorPrefs.getInt("minG", RAW_MIN);
  calMinB = colorPrefs.getInt("minB", RAW_MIN);
  calMaxR = colorPrefs.getInt("maxR", RAW_MAX);
  calMaxG = colorPrefs.getInt("maxG", RAW_MAX);
  calMaxB = colorPrefs.getInt("maxB", RAW_MAX);
  colorPrefs.end();
  Serial.printf("Color calibration loaded — white(R%d G%d B%d) black(R%d G%d B%d)\n",
    calMinR, calMinG, calMinB, calMaxR, calMaxG, calMaxB);
}

void saveColorCalibration() {
  colorPrefs.begin("colorcal", false);
  colorPrefs.putInt("minR", calMinR);
  colorPrefs.putInt("minG", calMinG);
  colorPrefs.putInt("minB", calMinB);
  colorPrefs.putInt("maxR", calMaxR);
  colorPrefs.putInt("maxG", calMaxG);
  colorPrefs.putInt("maxB", calMaxB);
  colorPrefs.end();
}

// Averages several raw readings per channel so a single noisy pulse doesn't
// get baked into the calibration.
void sampleColorRaw(unsigned long &avgR, unsigned long &avgG, unsigned long &avgB) {
  const int samples = 15;
  unsigned long sumR = 0, sumG = 0, sumB = 0;
  int counted = 0;

  for (int i = 0; i < samples; i++) {
    unsigned long r = readColorRaw(LOW, LOW);
    unsigned long g = readColorRaw(HIGH, HIGH);
    unsigned long b = readColorRaw(LOW, HIGH);
    if (r > 0 && g > 0 && b > 0) {
      sumR += r; sumG += g; sumB += b;
      counted++;
    }
    delay(20);
  }

  if (counted == 0) counted = 1; // avoid div-by-zero if every sample timed out
  avgR = sumR / counted;
  avgG = sumG / counted;
  avgB = sumB / counted;
}

void calibrateWhitePoint() {
  Serial.println("Calibrating WHITE point — hold a bright white surface against the sensor...");
  delay(1500);
  unsigned long r, g, b;
  sampleColorRaw(r, g, b);
  calMinR = (int)r; calMinG = (int)g; calMinB = (int)b;
  saveColorCalibration();
  Serial.printf("White point set: R%d G%d B%d\n", calMinR, calMinG, calMinB);
}

void calibrateBlackPoint() {
  Serial.println("Calibrating BLACK point — hold a dark/black surface against the sensor...");
  delay(1500);
  unsigned long r, g, b;
  sampleColorRaw(r, g, b);
  calMaxR = (int)r; calMaxG = (int)g; calMaxB = (int)b;
  saveColorCalibration();
  Serial.printf("Black point set: R%d G%d B%d\n", calMaxR, calMaxG, calMaxB);
}

void resetColorCalibration() {
  calMinR = calMinG = calMinB = RAW_MIN;
  calMaxR = calMaxG = calMaxB = RAW_MAX;
  saveColorCalibration();
  Serial.println("Color calibration reset to defaults.");
}

void handleSerialCommands() {
  if (!Serial.available()) return;
  switch (Serial.read()) {
    case 'w': case 'W': calibrateWhitePoint(); break;
    case 'k': case 'K': calibrateBlackPoint(); break;
    case 'r': case 'R': resetColorCalibration(); break;
  }
}

void updateColor() {
// Read Clear channel first (S2=HIGH, S3=LOW) as a contact/proximity check —
// see CONTACT_MAX_PULSE above for why the cutoff sits above the color range.
  unsigned long rawClear = readColorRaw(HIGH, LOW);
  Serial.print("RAW Clear:");
  Serial.println(rawClear);

  // Nothing close enough to trust: keep the last latched color
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

  latchedR = normalizeColor(rawRed, calMinR, calMaxR);
  latchedG = normalizeColor(rawGreen, calMinG, calMaxG);
  latchedB = normalizeColor(rawBlue, calMinB, calMaxB);
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
  pinMode(S0_PIN, OUTPUT);
  pinMode(S1_PIN, OUTPUT);
  pinMode(S2_PIN, OUTPUT);
  pinMode(S3_PIN, OUTPUT);
  pinMode(OUT_PIN, INPUT);

  // Set TCS3200 to 20% Frequency Scaling (S0 = HIGH, S1 = LOW)
  digitalWrite(S0_PIN, HIGH);
  digitalWrite(S1_PIN, LOW);

  Wire.begin(SDA_PIN, SCL_PIN);

  if (!mpu.begin()) {
    Serial.println("MPU6050 not found - check wiring!");
  } else {
    mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    Serial.println("MPU6050 ready.");
  }

  loadColorCalibration();

  setupWiFiAP();
  webSocket.begin();
  webSocket.onEvent(onWebSocketEvent);

  Serial.println("=== SpatialForge firmware ready, streaming over WebSocket ===");
  Serial.println("Color calibration: send 'w' (white surface), 'k' (black surface), 'r' (reset) over Serial.");
  lastIMUMicros = 0;
}

void loop() {
  webSocket.loop();
  handleSerialCommands();

  updateIMU();
  updateDistance();
  updateColor();

  unsigned long now = millis();
  if (now - lastStreamMillis >= STREAM_INTERVAL_MS) {
    lastStreamMillis = now;
    broadcastTelemetry();
  }
}