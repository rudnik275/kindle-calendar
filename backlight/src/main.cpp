// Підсвітка козирка: RP2040-Zero + енкодер + AO3400A (N-канал, ключ по мінусу).
//
// Енкодер — пʼять пінів підряд по лівому краю Zero, у тому ж порядку, що й на
// модулі: GND–GND, +–3V3, SW–GP29, DT–GP28, CLK–GP27.
// GP14 → 100 Ом → затвор AO3400A; 10 кОм затвор → GND тримає світло вимкненим,
// поки Zero вантажиться або прошивається. HIGH на затворі — світло.
//
// Ручка — як звичайний димер: 0 — темно, далі 48 кроків до 100 %. Крок — сталий
// множник яскравості (око бачить відношення, тож кожне клацання однаково помітне
// і внизу, і вгорі). Клік — вимкнути / увімкнути на останньому рівні, плавно.
// Рівень — у флеші через 5 с після останньої зміни.
// Serial (USB) друкує рівень — на стенді видно, що енкодер читається.

#include <Arduino.h>
#include <EEPROM.h>
#include <hardware/clocks.h>
#include <hardware/gpio.h>
#include <hardware/pwm.h>

const uint8_t PIN_PWM = 14, PIN_CLK = 27, PIN_DT = 28, PIN_SW = 29;

const uint32_t PWM_HZ = 20000;  // вище чутності, не мерехтить на камеру
const uint8_t STEPS = 48;       // кроків від мінімуму до 100 %
const int8_t DIRECTION = 1;     // крутиться навпаки — поставити -1
// Найкоротший імпульс на першому кроці. Коротше затвор не встигає відкритись
// (фронти ~0,1–0,3 мкс) — нитка або не світить, або світить нерівно. Підібрати
// на стенді: перший крок має ледь жевріти.
const uint32_t MIN_ON_NS = 200;
const uint16_t FADE_MS = 400;
const uint32_t SAVE_DELAY_MS = 5000;

const int EE_MAGIC = 0, EE_LEVEL = 1, EE_LAST_ON = 2;
const uint8_t MAGIC = 0x5B;

uint pwmSlice, pwmChan;
uint32_t period;  // тактів на період ШИМ = рівень «100 %»
uint32_t minOn;   // тактів на першому кроці

uint8_t level = 0;            // 0 — темно, 1..STEPS — світло
uint8_t lastOn = STEPS / 2;   // куди повертає клік
uint32_t duty = 0;            // поточне заповнення в тактах
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
  uint8_t s = (gpio_get(PIN_CLK) << 1) | gpio_get(PIN_DT);
  encState = ((encState << 2) | s) & 0x0F;
  encSub += QDEC[encState];
  if (s == 0b11) {
    if (encSub >= 2) encDetents++;
    else if (encSub <= -2) encDetents--;
    encSub = 0;
  }
}

int takeDetents() {
  noInterrupts();
  int d = encDetents;
  encDetents = 0;
  interrupts();
  return d * DIRECTION;
}

// ---- ШИМ ----
void pwmInit() {
  // До цього моменту пін — вхід із підтяжкою до землі (стан після скидання),
  // плюс 10 кОм на платі: лампа темна. Спершу рівень 0, потім віддаємо пін ШИМу.
  pwmSlice = pwm_gpio_to_slice_num(PIN_PWM);
  pwmChan = pwm_gpio_to_channel(PIN_PWM);
  uint32_t clk = clock_get_hz(clk_sys);
  period = clk / PWM_HZ;  // 125–200 МГц → 6250–10000 тактів
  minOn = (uint64_t)clk * MIN_ON_NS / 1000000000ULL;
  if (minOn < 1) minOn = 1;
  pwm_set_clkdiv_int_frac(pwmSlice, 1, 0);
  pwm_set_wrap(pwmSlice, period - 1);
  pwm_set_chan_level(pwmSlice, pwmChan, 0);
  pwm_set_enabled(pwmSlice, true);
  gpio_set_drive_strength(PIN_PWM, GPIO_DRIVE_STRENGTH_12MA);  // швидші фронти
  gpio_set_slew_rate(PIN_PWM, GPIO_SLEW_RATE_FAST);
  gpio_set_function(PIN_PWM, GPIO_FUNC_PWM);
}

// Рівень = period → вихід HIGH увесь період (100 %), 0 → LOW увесь період.
void setDuty(uint32_t d) {
  duty = d;
  pwm_set_chan_level(pwmSlice, pwmChan, d);
}

// Крок i (1..STEPS) → такти: геометрична прогресія від minOn до period.
uint32_t levelDuty(uint8_t i) {
  if (i == 0) return 0;
  float x = float(i - 1) / (STEPS - 1);
  return (uint32_t)lroundf(minOn * powf(float(period) / minOn, x));
}

// Плавно в логарифмі — тим самим «сталим множником», що й кроки.
void fadeTo(uint32_t target) {
  if (target == duty) return;
  const uint8_t frames = FADE_MS / 10;
  float a = logf(float(max(duty, minOn))), b = logf(float(max(target, minOn)));
  for (uint8_t k = 1; k < frames; k++) {
    setDuty((uint32_t)lroundf(expf(a + (b - a) * k / frames)));
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
  Serial.printf("level %2u/%u  duty %lu/%lu\n", level, STEPS, (unsigned long)duty,
                (unsigned long)period);
}

void touch() {
  dirty = true;
  changedAt = millis();
  report();
}

void setup() {
  pwmInit();

  pinMode(PIN_CLK, INPUT_PULLUP);  // на KY-040 є свої 10 кОм; внутрішні — для голого EC11
  pinMode(PIN_DT, INPUT_PULLUP);
  pinMode(PIN_SW, INPUT_PULLUP);
  encState = (gpio_get(PIN_CLK) << 1) | gpio_get(PIN_DT);
  attachInterrupt(digitalPinToInterrupt(PIN_CLK), encIsr, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_DT), encIsr, CHANGE);

  Serial.begin(115200);
  EEPROM.begin(256);
  if (EEPROM.read(EE_MAGIC) == MAGIC) {
    level = min<uint8_t>(EEPROM.read(EE_LEVEL), STEPS);
    lastOn = constrain(EEPROM.read(EE_LAST_ON), 1, STEPS);
  } else {
    level = lastOn;
  }
  Serial.printf("backlight: ready, PWM %lu Hz, %lu тактів, перший крок %lu\n",
                (unsigned long)PWM_HZ, (unsigned long)period, (unsigned long)minOn);
  fadeTo(levelDuty(level));
  report();
}

void loop() {
  int d = takeDetents();
  if (d != 0) {
    uint8_t next = constrain((int)level + d, 0, (int)STEPS);
    if (next != level) {
      level = next;
      if (level > 0) lastOn = level;
      setDuty(levelDuty(level));
      touch();
    }
  }

  if (clicked()) {
    level = level > 0 ? 0 : lastOn;
    fadeTo(levelDuty(level));
    touch();
  }

  if (dirty && millis() - changedAt > SAVE_DELAY_MS) {
    // commit() стирає й пише сектор флешу лише якщо щось змінилось.
    // 20 збережень на день — ~7 тис. на рік при ресурсі сектора ~100 тис.
    EEPROM.write(EE_MAGIC, MAGIC);
    EEPROM.write(EE_LEVEL, level);
    EEPROM.write(EE_LAST_ON, lastOn);
    EEPROM.commit();
    dirty = false;
    Serial.println("saved");
  }
}
