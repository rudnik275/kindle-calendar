// Підсвітка козирка: Arduino Nano + енкодер + AO3401 (P-канал, ключ по плюсу).
//
// Енкодер CLK → D2, DT → D3 (переривання INT0/INT1), SW → D4, + → 5V.
// D9 → 220 Ом → затвор AO3401; 10 кОм затвор → +5V тримає світло вимкненим,
// поки Nano вантажиться чи прошивається. LOW на затворі — світло, HIGH — темно.
//
// Ручка — як звичайний димер: 0 — темно, далі 10 кроків (пів оберту) до 100 %. Крок — сталий
// множник яскравості (око бачить відношення); унизу, де 10-бітного ШИМ на це
// не вистачає, — +1 такт на крок. Клік — вимкнути / увімкнути на останньому
// рівні, плавно. Після ввімкнення живлення — завжди темно; останній рівень
// (для кліку) — в EEPROM через 5 с після останньої зміни.
// Serial 115200 друкує рівень — на стенді видно, що енкодер читається.

#include <Arduino.h>
#include <EEPROM.h>

const uint8_t PIN_CLK = 2, PIN_DT = 3, PIN_SW = 4, PIN_PWM = 9;

// Timer1, Fast PWM 10 біт: 16 МГц / 1024 = 15,6 кГц — не мерехтить на камеру
// й не пищить. Такт — 62,5 нс.
const uint16_t PERIOD = 1024;
const uint8_t STEPS = 10;      // кроків від мінімуму до 100 % — пів оберту KY-040 (20 клацань/оберт)
const int8_t DIRECTION = -1;   // з цим енкодером за годинниковою — яскравіше (перевірено 25.11)
// Тактів на першому кроці. Коротше затвор через 220 Ом не встигає відкритись.
// Підібрати на стенді: перший крок має ледь жевріти.
const uint16_t MIN_DUTY = 3;
const uint16_t FADE_MS = 400;
const uint32_t SAVE_DELAY_MS = 5000;

const int EE_MAGIC = 0, EE_LAST_ON = 2;  // адреса 1 (рівень) більше не пишемо
const uint8_t MAGIC = 0x5C;

uint16_t table[STEPS + 1];   // крок → такти «світло»
uint8_t level = 0;           // 0 — темно, 1..STEPS — світло
uint8_t lastOn = STEPS / 2;  // куди повертає клік
uint16_t duty = 0;
bool dirty = false;
uint32_t changedAt = 0;

// ---- енкодер ----
// Квадратурний декодер на перериваннях: таблиця пропускає неможливі переходи
// (брязкіт контактів), клацання зараховується лише в положенні фіксатора
// (обидва контакти розімкнені = 0b11) і лише якщо пройдено пів циклу.
// Так рахує KY-040 / EC11 «20 імпульсів на 20 клацань».
const int8_t QDEC[16] = {0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0};
volatile uint8_t encState = 0b11;
volatile int8_t encSub = 0;
volatile int16_t encDetents = 0;

void encIsr() {
  uint8_t s = (digitalRead(PIN_CLK) << 1) | digitalRead(PIN_DT);
  encState = ((encState << 2) | s) & 0x0F;
  encSub += QDEC[encState];
  if (s == 0b11) {
    if (encSub >= 2) encDetents++;
    else if (encSub <= -2) encDetents--;
    encSub = 0;
  }
}

int takeDetents() {
  noInterrupts();  // 16-бітне читання на AVR не атомарне
  int d = encDetents;
  encDetents = 0;
  interrupts();
  return d * DIRECTION;
}

// ---- ШИМ ----
// Вихід OC1A (D9) інверсний: «світло» — LOW-частина періоду завдовжки OCR1A + 1
// тактів; OCR1A = TOP дає LOW увесь період (100 %).
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

// Геометрична прогресія від MIN_DUTY до PERIOD; де сусідні кроки збігаються
// після округлення (унизу) — щонайменше +1 такт, щоб кожне клацання було помітне.
void buildTable() {
  table[0] = 0;
  for (uint8_t i = 1; i <= STEPS; i++) {
    float x = float(i - 1) / (STEPS - 1);
    uint16_t v = (uint16_t)(MIN_DUTY * pow(float(PERIOD) / MIN_DUTY, x) + 0.5);
    if (i > 1 && v <= table[i - 1]) v = table[i - 1] + 1;
    table[i] = min(v, PERIOD);
  }
  table[STEPS] = PERIOD;
}

// Плавно в логарифмі — тим самим «сталим множником», що й кроки.
void fadeTo(uint16_t target) {
  if (target == duty) return;
  const uint8_t frames = FADE_MS / 10;
  float a = log(float(max(duty, MIN_DUTY))), b = log(float(max(target, MIN_DUTY)));
  for (uint8_t k = 1; k < frames; k++) {
    setDuty((uint16_t)(exp(a + (b - a) * k / frames) + 0.5));
    delay(10);
  }
  setDuty(target);
}

// ---- кнопка ----
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

void report() {
  Serial.print(F("level "));
  Serial.print(level);
  Serial.print('/');
  Serial.print(STEPS);
  Serial.print(F("  duty "));
  Serial.print(duty);
  Serial.print('/');
  Serial.println(PERIOD);
}

void touch() {
  dirty = true;
  changedAt = millis();
  report();
}

void setup() {
  pwmInit();
  setDuty(0);
  buildTable();

  pinMode(PIN_CLK, INPUT_PULLUP);  // на KY-040 є свої 10 кОм; внутрішні — для голого EC11
  pinMode(PIN_DT, INPUT_PULLUP);
  pinMode(PIN_SW, INPUT_PULLUP);
  encState = (digitalRead(PIN_CLK) << 1) | digitalRead(PIN_DT);
  attachInterrupt(digitalPinToInterrupt(PIN_CLK), encIsr, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_DT), encIsr, CHANGE);

  Serial.begin(115200);
  // Після ввімкнення живлення завжди темно (рівень 0): світло — енкодером
  // (з мінімуму) або кліком (останній рівень, він пережив вимкнення).
  if (EEPROM.read(EE_MAGIC) == MAGIC) {
    lastOn = constrain(EEPROM.read(EE_LAST_ON), 1, STEPS);
  }
  Serial.println(F("backlight: ready"));
  report();
}

void loop() {
  int d = takeDetents();
  if (d != 0) {
    uint8_t next = constrain((int)level + d, 0, (int)STEPS);
    if (next != level) {
      level = next;
      if (level > 0) lastOn = level;
      setDuty(table[level]);
      touch();
    }
  }

  if (clicked()) {
    level = level > 0 ? 0 : lastOn;
    fadeTo(table[level]);
    touch();
  }

  if (dirty && millis() - changedAt > SAVE_DELAY_MS) {
    EEPROM.update(EE_MAGIC, MAGIC);
    EEPROM.update(EE_LAST_ON, lastOn);
    dirty = false;
    Serial.println(F("saved"));
  }
}
