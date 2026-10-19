// Підсвітка козирка: Arduino Nano + енкодер + AO3401 (P-канал, ключ по плюсу).
//
// Енкодер CLK → D2, DT → D3 (обидва на перериваннях), SW → D4.
// D9 → 220 Ом → затвор AO3401, 10 кОм затвор → +5V тримає світло вимкненим,
// поки Nano вантажиться. LOW на затворі — світло, HIGH — темно.
//
// Поворот — крок яскравості по гамма-кривій (унизу кроки дрібніші, око бачить
// рівно). Клік — вкл/викл із памʼяттю рівня, плавно. Поворот у вимкненому
// стані вмикає. Рівень і стан — в EEPROM через 5 с після останньої зміни.
// Serial 115200 друкує рівень — на стенді видно, що енкодер читається.

#include <Arduino.h>
#include <EEPROM.h>
#include <Encoder.h>

const uint8_t PIN_CLK = 2, PIN_DT = 3, PIN_SW = 4, PIN_PWM = 9;

const uint8_t STEPS = 48;             // кроків від мінімуму до 100 %
const uint8_t COUNTS_PER_DETENT = 4;  // KY-040: 4 імпульси на одне клацання
const int8_t DIRECTION = 1;           // крутиться навпаки — поставити -1
const uint16_t MIN_DUTY = 3;          // тактів із 1024 на першому кроці; тьмяніше
                                      // затвор через 220 Ом уже не встигає відкритись
const float GAMMA = 2.2;
const uint16_t FADE_MS = 300;
const uint32_t SAVE_DELAY_MS = 5000;

const int EE_MAGIC = 0, EE_LEVEL = 1, EE_ON = 2;
const uint8_t MAGIC = 0x5A;

Encoder enc(PIN_CLK, PIN_DT);
uint8_t level = STEPS / 2;  // 1..STEPS
bool on = true;
uint16_t duty = 0;          // тактів «світло» з 1024; 0 — повна темрява
bool dirty = false;
uint32_t changedAt = 0;

// Timer1, Fast PWM 10 біт (TOP = 0x3FF), без дільника → 16 МГц / 1024 = 15,6 кГц:
// не мерехтить на камеру й не пищить. Вихід OC1A (D9) інверсний — «світло» це
// LOW-частина періоду завдовжки OCR1A + 1 тактів.
void pwmInit() {
  digitalWrite(PIN_PWM, HIGH);  // спершу підтяжка, потім вихід — без спалаху
  pinMode(PIN_PWM, OUTPUT);
  TCCR1A = _BV(WGM11) | _BV(WGM10);
  TCCR1B = _BV(WGM12) | _BV(CS10);
}

void setDuty(uint16_t d) {
  duty = d;
  if (d == 0) {
    // Інверсний ШИМ навіть при OCR1A = 0 лишає 1 такт LOW і нитка тліє —
    // тому вимикаємо його зовсім і тримаємо HIGH.
    TCCR1A &= ~(_BV(COM1A1) | _BV(COM1A0));
    digitalWrite(PIN_PWM, HIGH);
  } else {
    OCR1A = d - 1;
    TCCR1A |= _BV(COM1A1) | _BV(COM1A0);
  }
}

uint16_t levelDuty(uint8_t i) {
  float x = (float)i / STEPS;
  uint16_t d = MIN_DUTY + (uint16_t)((1024 - MIN_DUTY) * pow(x, GAMMA) + 0.5);
  uint16_t atLeast = MIN_DUTY + i - 1;  // кожен крок помітний, навіть де крива пласка
  return d < atLeast ? atLeast : d;
}

// Плавно в «очному» просторі: інтерполюємо duty^(1/γ), а не сам duty.
void fadeTo(uint16_t target) {
  const uint8_t frames = FADE_MS / 10;
  float a = pow(duty / 1024.0, 1 / GAMMA), b = pow(target / 1024.0, 1 / GAMMA);
  for (uint8_t k = 1; k < frames; k++) {
    float x = a + (b - a) * k / frames;
    setDuty((uint16_t)(1024 * pow(x, GAMMA) + 0.5));
    delay(10);
  }
  setDuty(target);
}

void report() {
  Serial.print(on ? F("on  ") : F("off "));
  Serial.print(F("level "));
  Serial.print(level);
  Serial.print('/');
  Serial.print(STEPS);
  Serial.print(F("  duty "));
  Serial.print(on ? levelDuty(level) : 0);
  Serial.println(F("/1024"));
}

void touch() {
  dirty = true;
  changedAt = millis();
  report();
}

bool clicked() {
  static bool raw = HIGH, stable = HIGH;
  static uint32_t edgeAt = 0;
  bool r = digitalRead(PIN_SW);
  if (r != raw) {
    raw = r;
    edgeAt = millis();
  }
  if (millis() - edgeAt > 30 && r != stable) {
    stable = r;
    return stable == LOW;
  }
  return false;
}

void setup() {
  pwmInit();
  setDuty(0);
  pinMode(PIN_SW, INPUT_PULLUP);
  Serial.begin(115200);

  if (EEPROM.read(EE_MAGIC) == MAGIC) {
    level = constrain(EEPROM.read(EE_LEVEL), 1, STEPS);
    on = EEPROM.read(EE_ON) != 0;
  }
  Serial.println(F("backlight: ready"));
  report();
  if (on) fadeTo(levelDuty(level));
}

void loop() {
  long pos = enc.read();
  long detents = pos / COUNTS_PER_DETENT;
  if (detents != 0) {
    enc.write(pos - detents * COUNTS_PER_DETENT);
    level = constrain((int)level + DIRECTION * detents, 1, STEPS);
    if (on) {
      setDuty(levelDuty(level));
    } else {
      on = true;
      fadeTo(levelDuty(level));
    }
    touch();
  }

  if (clicked()) {
    on = !on;
    fadeTo(on ? levelDuty(level) : 0);
    touch();
  }

  if (dirty && millis() - changedAt > SAVE_DELAY_MS) {
    EEPROM.update(EE_MAGIC, MAGIC);
    EEPROM.update(EE_LEVEL, level);
    EEPROM.update(EE_ON, on);
    dirty = false;
    Serial.println(F("saved"));
  }
}
