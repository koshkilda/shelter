-- ----------------------------------------------------------------------------
-- ЧАСТЬ 0: ОЧИСТКА СТАРЫХ ДАННЫХ
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS tasks CASCADE;
DROP TABLE IF EXISTS monthly_expenses CASCADE;
DROP TABLE IF EXISTS expense_categories CASCADE;
DROP TABLE IF EXISTS adoptions CASCADE;
DROP TABLE IF EXISTS owners CASCADE;
DROP TABLE IF EXISTS stock_moves CASCADE;
DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS health_metrics CASCADE;
DROP TABLE IF EXISTS medical_records CASCADE;
DROP TABLE IF EXISTS animals CASCADE;


-- ----------------------------------------------------------------------------
-- ЧАСТЬ 1: СТРУКТУРА ТАБЛИЦ (DDL)
-- ----------------------------------------------------------------------------
-- 1. Сущность: Животные
CREATE TABLE animals (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    species         VARCHAR(50)  NOT NULL,
    breed           VARCHAR(100),
    birth_date      DATE,
    intake_date     DATE         NOT NULL DEFAULT CURRENT_DATE,

    lifecycle_status VARCHAR(30) NOT NULL DEFAULT 'available'
                    CONSTRAINT chk_animal_lifecycle CHECK (
                        lifecycle_status IN ('quarantine','available','adopted','deceased')
                    ),

    current_condition VARCHAR(20)
                    CONSTRAINT chk_animal_condition CHECK (
                        current_condition IN ('health','treatment','observation')
                    ),

    CONSTRAINT chk_animal_birth_intake CHECK (
        birth_date IS NULL
        OR birth_date <= intake_date
    )
);

-- 2. Сущность: Медицинские записи
CREATE TABLE medical_records (
    id          SERIAL PRIMARY KEY,
    animal_id   INT           NOT NULL REFERENCES animals(id) ON DELETE CASCADE,
    record_type VARCHAR(30)   NOT NULL
                CHECK (record_type IN ('exam','vaccination','treatment','surgery')),
    record_date DATE          NOT NULL DEFAULT CURRENT_DATE,
    diagnosis   TEXT,
    treatment   TEXT,
    cost        DECIMAL(10,2) 
);

-- 3. Сущность: Метрики здоровья (временные ряды)
CREATE TABLE health_metrics (
    id          SERIAL PRIMARY KEY, 
    time        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    animal_id   INT           NOT NULL REFERENCES animals(id) ON DELETE CASCADE,
    weight_kg   DECIMAL(5,2), 
    temperature DECIMAL(4,2),
    bcs         INT           CHECK (bcs BETWEEN 1 AND 9)
);

-- 4. Складской учет: Каталог товаров (статика)
CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(150) NOT NULL UNIQUE,
    category    VARCHAR(50)  NOT NULL, -- 'food', 'medicine', 'equipment'
    unit        VARCHAR(20)  NOT NULL DEFAULT 'шт'
);

-- 5. Складской учет: Текущие остатки (Баланс)
CREATE TABLE inventory (
    product_id      INT           NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity        DECIMAL(10,3) NOT NULL CHECK (quantity >= 0),
    min_threshold   DECIMAL(10,3) NOT NULL DEFAULT 0,
    last_updated    TIMESTAMPTZ   DEFAULT NOW(),
    PRIMARY KEY (product_id)
);

-- 6. Складской учет: Журнал движений (История)
CREATE TABLE stock_moves (
    id              SERIAL PRIMARY KEY,
    product_id      INT           NOT NULL REFERENCES products(id),
    change_qty      DECIMAL(10,3) NOT NULL CHECK (change_qty > 0), 
    move_type       VARCHAR(20)   NOT NULL CHECK (move_type IN ('IN', 'OUT')),
    reference_table VARCHAR(50),  -- table name            
    reference_id    INT,          -- id from reference table         
    moved_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- 7. Процесс усыновления: Владельцы (Справочник людей)
CREATE TABLE owners (
    id          SERIAL PRIMARY KEY,
    full_name   VARCHAR(150) NOT NULL,
    phone       VARCHAR(20),
    email       VARCHAR(100),
    address     TEXT
);

-- 8. Процесс усыновления: История передач (Факты событий)
CREATE TABLE adoptions (
    id              SERIAL PRIMARY KEY,
    owner_id        INT           NOT NULL REFERENCES owners(id),
    animal_id       INT           NOT NULL REFERENCES animals(id),
    adoption_date   DATE          NOT NULL DEFAULT CURRENT_DATE,
    return_date     DATE,
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    feedback_note   TEXT,

    CONSTRAINT chk_adoption_logic CHECK (
        (is_active = TRUE AND return_date IS NULL)
        OR
        (is_active = FALSE AND return_date IS NOT NULL)
    ),

    CONSTRAINT chk_adoption_return_date CHECK (
        return_date IS NULL
        OR return_date >= adoption_date
    )
);
CREATE UNIQUE INDEX uq_active_adoption_per_animal
ON adoptions(animal_id) WHERE is_active = TRUE;

-- 9. Финансы: Категории расходов
CREATE TABLE expense_categories (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE
);

-- 10. Финансы: Фактические траты
CREATE TABLE monthly_expenses (
    id           SERIAL PRIMARY KEY,
    category_id  INT           NOT NULL REFERENCES expense_categories(id),
    expense_date DATE          NOT NULL DEFAULT CURRENT_DATE,
    amount       DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    note         TEXT
);

-- 11. Задачи волонтеров
CREATE TABLE tasks (
    id        SERIAL PRIMARY KEY,
    animal_id INT          REFERENCES animals(id) ON DELETE CASCADE,
    kind      VARCHAR(30)  NOT NULL
              CHECK (kind IN ('feed','walk','vet_visit','clean','restock','check')),
    due_date  DATE         NOT NULL,
    done      BOOLEAN      NOT NULL DEFAULT FALSE,
    note      TEXT
);

-- Индексы для производительности
CREATE INDEX idx_mr_animal ON medical_records(animal_id);
CREATE INDEX idx_hm_animal_time ON health_metrics(animal_id, time DESC);
CREATE INDEX idx_stock_prod ON stock_moves(product_id);
CREATE INDEX idx_tasks_due_done ON tasks(due_date, done);
CREATE INDEX idx_adopt_animal ON adoptions(animal_id);
CREATE INDEX idx_adopt_owner ON adoptions(owner_id);



-- ТРИГГЕР: автоматическое обновление остатков при движении товара
CREATE OR REPLACE FUNCTION fn_apply_stock_move()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO inventory (product_id, quantity, min_threshold)
    VALUES (NEW.product_id, 0, 0)
    ON CONFLICT (product_id) DO NOTHING;

    IF NEW.move_type = 'IN' THEN
        UPDATE inventory
        SET quantity = quantity + NEW.change_qty,
            last_updated = NOW()
        WHERE product_id = NEW.product_id;

    ELSIF NEW.move_type = 'OUT' THEN
        UPDATE inventory
        SET quantity = quantity - NEW.change_qty,
            last_updated = NOW()
        WHERE product_id = NEW.product_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_stock_move
AFTER INSERT ON stock_moves
FOR EACH ROW
EXECUTE FUNCTION fn_apply_stock_move();


-- ----------------------------------------------------------------------------
-- ЧАСТЬ 2: ТЕСТОВЫЕ ДАННЫЕ (DML)
-- ----------------------------------------------------------------------------

-- 1. Животные (включая Барсика для примера истории усыновления)
INSERT INTO animals (name, species, breed, birth_date, intake_date, lifecycle_status, current_condition) VALUES
('Дымик',     'cat',     NULL,                        '2008-11-01', '2010-08-01', 'deceased',  NULL),
('Плюша',     'dog',     'Корги',                     '2020-09-10', '2022-05-16', 'available', 'health'), -- health, но было лечение от цистита
('Кишка',     'cat',     NULL,                        '2022-05-01', '2022-06-15', 'available', 'health'), -- была втоаря дырка в попе (рана), отравление - съела ластик
('Яша',       'cat',     NULL,                        '2013-01-01', '2017-03-05', 'available', 'health'),
('Бетти',     'dog',     'Английский кокер-спаниель', '2016-03-27', '2017-02-25', 'adopted',   'treatment'), -- болят уши 
('Буся',      'cat',     'Британская шиншилла',       '2014-08-15', '2015-12-25', 'adopted',   'treatment'), --зубной камень
('Чипиздрик', 'hamster', 'Сирийский',                 '2024-06-30', '2024-07-03', 'available', 'observation'), -- облысение
('Софи',      'cat',     'Шотландская вислоухая',     '2021-05-11', '2023-02-09', 'available', 'observation'); -- остеохондродистрофия

-- 2. Медзаписи
DELETE FROM medical_records WHERE animal_id = 1; 
INSERT INTO medical_records (animal_id, record_type, record_date, diagnosis, treatment, cost) VALUES
-- Дымик
(1, 'exam',        '2010-08-02', 'Первичный осмотр. Кошка худая, активных жалоб нет.', 'Вакцинация, дегельминтизация', 800.00),
(1, 'vaccination', '2011-08-05', 'Ревакцинация комплексная', 'Nobivac Tricat', 900.00),
(1, 'exam',        '2015-08-10', 'Плановый осмотр. Вес 2.2 кг. Анализы крови в норме.', 'Биохимия, общий анализ мочи', 1500.00),
(1, 'exam',        '2016-03-15', 'Найдено образование хвоста поджелудочной железы при УЗИ брюшной полости.', 'УЗИ, биопсия (назначена)', 2500.00),
(1, 'surgery',     '2016-04-02', 'Дистальная панкреатэктомия (удаление опухоли с частью железы).', 'Наркоз, операция, стационар 3 дня', 12000.00),
(1, 'exam',        '2016-04-10', 'Послеоперационное наблюдение. Швы сняты. Заживление хорошее.', 'Обработка швов, обезболивание', 1200.00),
(1, 'treatment',   '2016-05-20', 'Сахарный диабет 1 типа (вторичный после резекции поджелудочной). Гипергликемия натощак.', 'Подбор дозы инсулина (Lantus/Glargine), диета diabetic', 3500.00),
(1, 'exam',        '2017-06-01', 'Контроль гликированного гемоглобина (Fructosamine). Компенсация стабильная.', 'Анализ Fructosamine, коррекция дозы', 2200.00),
(1, 'treatment',   '2018-01-15', 'Сезонное обострение. Небольшие скачки сахара.', 'Коррекция рациона, увеличение физической активности', 800.00),
(1, 'exam',        '2019-06-10', 'Плановый контроль. Почки страдают (ХПН начальной стадии) из-за длительного диабета.', 'Диета renal + diabetic, фосфорсвязывающие', 3000.00),
(1, 'treatment',   '2020-02-10', 'Резкое ухудшение состояния. Вялость, отказ от еды.', 'Инфузионная терапия, глюкометр каждые 4 часа', 4500.00),
(1, 'exam',        '2020-03-05', 'Диабетический кетоацидоз. Тяжелое состояние.', 'Стационар, капельницы, кислород', 8000.00),
(1, 'exam',        '2020-04-20', 'Отказ почек на фоне диабета. Необратимые изменения.', 'Паллиативная помощь, обезболивание', 2500.00),
(1, 'exam',        '2020-05-15', 'Эвтаназия по медицинским показаниям (неконтролируемая боль, терминальная стадия ХПН/Диабета).', 'Гуманное усыпление', 1500.00),
-- Плюша
(2, 'exam',        '2022-05-17', 'Цистит, воспаление мочевого пузыря', 'Антибиотики, спазмолитики', 1800.00),
(2, 'vaccination', '2022-06-01', 'Комплексная вакцинация (щенок)', 'Вакцина Nobivac DHPPi-L4', 1200.00),
(2, 'exam',        '2023-05-20', 'Профилактический осмотр, здоровье норма', 'Осмотр зубов, шерсти', 600.00),

-- Кишка 
(3, 'exam',        '2022-06-15', 'Первичный осмотр при поступлении. Глубокая рваная рана задней поверхности бедра (левое). Кровотечение остановлено.', 'Санация раны, обезболивание, рентген кости (исключить перелом)', 1500.00),
(3, 'surgery',     '2022-06-16', 'Хирургическая обработка раны бедра. Некротические ткани удалены.', 'Наложение узловых швов, дренаж, местная анестезия + седация', 4500.00),
(3, 'treatment',   '2022-06-20', 'Профилактика инфекции после операции.', 'Курс антибиотиков (Амоксициллин), перевязки каждые 2 дня', 1200.00),
(3, 'exam',        '2022-07-05', 'Контрольный осмотр. Заживление первичным натяжением. Швы сняты.', 'Обработка рубца, рекомендации по ограничению подвижности', 800.00),
(3, 'treatment',   '2025-01-20', 'Рвота, отказ от еды, болезненность живота, нарушение координации. Подозрение на непроходимость.', 'УЗИ брюшной полости, рентген с контрастом', 2500.00),
(3, 'surgery',     '2025-01-21', 'Инородное тело (ластик) в тонком кишечнике. Лапаротомия.', 'Извлечение предмета, ревизия кишечника, ушивание стенки', 8500.00),
(3, 'treatment',   '2025-01-25', 'Послеоперационный период. Профилактика спаек и инфекций.', 'Инфузионная терапия, антибиотики широкого спектра, диета Gastrointestinal', 3000.00),
(3, 'exam',        '2025-02-05', 'Выписка. Аппетит восстановлен, стул нормальный.', 'Контроль состояния, назначение пробиотиков', 600.00),

-- Яша
(4, 'vaccination', '2017-03-10', 'Первичная вакцинация после карантина', 'Комплексная вакцина', 1100.00),
(4, 'exam',        '2024-01-15', 'Плановый осмотр, возраст 11 лет', 'Биохимия крови, анализ мочи', 2800.00),

-- Бетти
(5, 'treatment',   '2017-03-01', 'Хронический отит, грибок в ушах', 'Местные капли, чистка ушей', 900.00),
(5, 'exam',        '2018-03-05', 'Рецидив отита', 'Культура на чувствительность, антибиотики', 2200.00),
(5, 'treatment',   '2024-09-10', 'Поддерживающая терапия отита', 'Еженедельная обработка ушей', 500.00),

-- Буся 
(6, 'surgery',     '2016-01-10', 'Зубной камень, гингивит', 'Стоматологическая чистка ультразвуком, санация', 6500.00),
(6, 'exam',        '2020-05-20', 'Профилактическая чистка зубов', 'Ультразвуковая чистка, полировка', 4000.00),
(6, 'treatment',   '2024-08-15', 'Воспаление десен (пародонтит)', 'Аппликации, диета мягкая', 1200.00),

-- Чипиздрик
(7, 'exam',        '2024-07-05', 'Локальное облысение, зуд', 'Соскоб кожи, исключение демодекоза', 800.00),
(7, 'treatment',   '2024-07-10', 'Аллергический дерматит (реакция на наполнитель)', 'Смена наполнителя на бумагу, антигистаминные', 600.00),

-- Софи
(8, 'exam',        '2023-02-15', 'Болезнь опорно-двигательного аппарата (СКД)', 'Рентген позвоночника, суставов', 3500.00),
(8, 'treatment',   '2023-03-01', 'Обострение боли в суставах', 'НПВС (Мелоксикам), хондропротекторы', 1800.00),
(8, 'treatment',   '2024-09-01', 'Поддерживающая терапия артроза', 'Физиотерапия, массаж, добавки Glucosamine', 2500.00);

-- 3. Метрики здоровья
INSERT INTO health_metrics (time, animal_id, weight_kg, temperature, bcs) VALUES
('2010-08-02', 1, 2.2, 38.5, 3), 
('2015-08-10', 1, 2.0, 38.6, 2), 
('2016-04-10', 1, 1.8, 38.2, 2), 
('2016-06-01', 1, 1.9, 38.0, 2),
('2017-06-01', 1, 3.6, 38.4, 4), 
('2019-06-10', 1, 4.5, 38.3, 5), 
('2020-02-10', 1, 3.5, 37.8, 3), 
('2020-04-20', 1, 2.9, 37.2, 2),
(NOW() - INTERVAL '4 years', 2, 8.5, 38.8, 5),
(NOW() - INTERVAL '1 year',  2, 12.2, 38.5, 6),
('2022-06-15', 3, 3.2, 38.9, 3), 
('2022-06-17', 3, 3.1, 39.1, 3), 
('2022-07-20', 3, 3.8, 38.6, 4), 
('2023-01-10', 3, 4.2, 38.5, 5), 
('2023-08-10', 3, 3.9, 38.8, 4), 
('2023-09-01', 3, 4.3, 38.6, 5),
(NOW() - INTERVAL '3 years', 8, 4.0, 38.5, 5),
(NOW() - INTERVAL '1 year',  8, 4.2, 38.6, 6), 
(NOW() - INTERVAL '1 month', 8, 4.1, 38.5, 6);

-- 4. Товары на складе (Специфика под лечение)
INSERT INTO products (name, category, unit) VALUES
('Корм сухой Royal Canin Diabetic', 'food', 'кг'),      -- Для Дымикa (диабет)
('Корм влажный Gastrointestinal',   'food', 'шт'),      -- Для Кишки (после операции ЖКТ)
('Инсулин Lantus Glargine',         'medicine', 'уп'),  -- Для Дымикa
('Антибиотик Амоксициллин',         'medicine', 'уп'),  -- Для Кишки и Плюши
('Наполнитель бумажный CatStep',    'consumable', 'л'), -- Для Чипиздрика (аллергия) и общего пользования
('Шампунь Otodect',                 'equipment', 'шт'), -- Для Бетти (уши)
('Хондропротектор Glucosamine',     'medicine', 'уп');  -- Для Софи (суставы)

-- 5. Текущие остатки
INSERT INTO inventory (product_id, quantity, min_threshold) VALUES
(1, 0.0, 5.0),   -- Диетический корм
(2, 0.0, 10.0),  -- Влажный GI
(3, 0.0, 2.0),   -- Инсулин
(4, 0.0, 5.0),   -- Антибиотик
(5, 0.0, 20.0),  -- Наполнитель
(6, 0.0, 1.0),   -- Шампунь
(7, 0.0, 3.0);   -- Хондропротектор

-- 6. История движений товара 
-- 6. История движений товара
INSERT INTO stock_moves (product_id, change_qty, move_type, reference_table, reference_id) VALUES
(1, 20.0, 'IN', 'purchase', NULL),   -- корм диабетический
(2, 24.0, 'IN', 'purchase', NULL),   -- влажный Gastrointestinal
(3, 5.0,  'IN', 'purchase', NULL),   -- инсулин
(4, 10.0, 'IN', 'purchase', NULL),   -- антибиотик
(5, 50.0, 'IN', 'purchase', NULL),   -- наполнитель
(6, 3.0,  'IN', 'purchase', NULL),   -- шампунь
(7, 5.0,  'IN', 'purchase', NULL),   -- хондропротектор
(3, 4.0, 'OUT', 'medical_records', 7),   -- инсулин для Дымика
(1, 2.5, 'OUT', 'medical_records', 7),   -- диабетический корм для Дымика
(4, 2.0, 'OUT', 'medical_records', 20),  -- антибиотик Кишке после операции на бедре
(4, 3.0, 'OUT', 'medical_records', 24),  -- антибиотик Кишке после лапаротомии
(2, 6.0, 'OUT', 'medical_records', 24),  -- влажный корм Кишке после операции
(5, 5.0, 'OUT', 'medical_records', 35),  -- наполнитель для Чипиздрика при аллергии
(6, 1.0, 'OUT', 'medical_records', 30),  -- шампунь Бетти при отите
(7, 1.0, 'OUT', 'medical_records', 38);  -- хондропротектор Софи

-- 7. Владельцы 
INSERT INTO owners (full_name, phone, address) VALUES 
('Евстюничева Ю.А.', '+79001112233', 'г. Москва, ул. Садовая, д. 10'), 
('Наумова А.А.',     '+79004445566', 'г. Москва, пр. Мира,    д. 5');   

-- 8. История усыновлений
INSERT INTO adoptions (owner_id, animal_id, adoption_date, return_date, is_active, feedback_note) VALUES
(1, 5, '2017-03-01', NULL, TRUE, 'Усыновлена семьей Евстюничевых, регулярно посещает клинику приюта'),
(2, 6, '2016-01-15', NULL, TRUE, 'Усыновлена семьей Наумовых, плановые визиты к стоматологу');

-- 9. Категории расходов 
INSERT INTO expense_categories (name) VALUES
('аренда'), 
('коммунальные'), 
('корм'), 
('ветпрепараты'), 
('хозтовары'), 
('прочее'),
('специализированное питание'); 

-- 10. Фактические расходы (Привязываем даты к событиям из medical_records)
INSERT INTO monthly_expenses (category_id, expense_date, amount, note) VALUES
(1, '2026-09-05', 25000.00, 'аренда помещения, сентябрь'),
(2, '2026-09-07',  4300.50, 'свет и вода'),

-- Расходы на лечение Дымикa (исторические, для статистики)
(4, '2016-04-02', 12000.00, 'Оплата панкреатэктомии Дымикa'),
(4, '2016-06-01', 3500.00, 'Закупка инсулина Lantus для Дымикa'),

-- Расходы на лечение Кишки
(4, '2022-06-16', 4500.00, 'Хирургия раны бедра Кишки'),
(4, '2022-06-20', 1200.00, 'Курс амоксициллина для Кишки'),
(4, '2025-01-21', 8500.00, 'Экстренная операция по удалению инородного тела (Кишка)'),
(3, '2025-01-25', 3000.00, 'Диета GI и капельницы для Кишки'),

-- Расходы на Чипиздрика (наполнитель)
(5, '2024-07-10', 600.00, 'Закупка специального бумажного наполнителя'),

-- Расходы на Софи (хондропротекторы)
(4, '2024-09-01', 2500.00, 'Курс глюкозамина для Софи'),

-- Текущие закупки корма (общие)
(3, '2026-09-12', 8700.00, 'Закупка сухого корма Royal Canin Diabetic и обычного'),
(5, '2026-09-14', 1950.00, 'Моющие средства, швабры, расходники');


-- 11. Задачи волонтеров 
INSERT INTO tasks (animal_id, kind, due_date, done, note) VALUES
(7, 'check',     (CURRENT_DATE + 1)::DATE,  FALSE, 'Чипиздрик: осмотр кожи, нет ли новых очагов облысения'),
(8, 'vet_visit', (CURRENT_DATE + 3)::DATE,  FALSE, 'Софи: контрольный рентген позвоночника перед сезоном холодов'),
(8, 'clean',     CURRENT_DATE,              TRUE,  'Софи: замена лежанки на ортопедическую'),
(2, 'feed',      CURRENT_DATE,              FALSE, 'Плюша: контроль порции, следим за весом'),
(4, 'walk',      (CURRENT_DATE + 2)::DATE,  FALSE, 'Яша: спокойная прогулка, избегая резких движений'),
(NULL, 'restock', (CURRENT_DATE + 7)::DATE, FALSE, 'Заказать партию инсулина Lantus: остаток ниже порога'),
(NULL, 'restock', (CURRENT_DATE + 7)::DATE, FALSE, 'Докупить антибиотик Амоксициллин: остаток на критическом уровне'),
(NULL, 'clean',   CURRENT_DATE,             FALSE, 'Генеральная уборка ветеринарного кабинета после приема Софи'),
(NULL, 'check',   (CURRENT_DATE + 30)::DATE,FALSE, 'Инвентаризация склада медикаментов: сверка stock_moves и inventory');


-- ----------------------------------------------------------------------------
-- ЧАСТЬ 3: АНАЛИТИЧЕСКИЕ ЗАПРОСЫ
-- ----------------------------------------------------------------------------

/* 
   ЗАПРОС 1: JOIN
   Цель: Показать медицинские события вместе с именами животных.
*/
SELECT a.name, a.species, m.record_type, m.diagnosis, m.treatment
FROM animals a
JOIN medical_records m ON m.animal_id = a.id
ORDER BY a.name;

/* 
   ЗАПРОС 2: GROUP BY + HAVING
   Цель: Найти животных, лечение которых обошлось дороже 2000 руб.
*/
SELECT a.id, a.name, SUM(m.cost) AS total_cost
FROM animals a
JOIN medical_records m ON m.animal_id = a.id
GROUP BY a.id, a.name
HAVING SUM(m.cost) > 2000
ORDER BY total_cost DESC;

/* 
   ЗАПРОС 3: CASE WHEN + JOIN
   Цель: Подсветить товары на складе, требующие заказа.
*/
SELECT 
    p.name AS item_name,
    i.quantity AS current_stock,
    i.min_threshold AS reorder_level,
    CASE
        WHEN i.quantity <= i.min_threshold THEN 'ЗАКАЗАТЬ'
        ELSE 'OK'
    END AS alert_status
FROM inventory i
JOIN products p ON p.id = i.product_id
ORDER BY alert_status DESC, p.name;

/* 
   ЗАПРОС 4: Оконная функция ROW_NUMBER() + CTE
   Цель: Определить медицинский статус каждого животного на основе САМОГО СВЕЖЕГО измерения BCS.
*/
WITH latest_metrics AS (
    SELECT animal_id, time, weight_kg, bcs,
           ROW_NUMBER() OVER (PARTITION BY animal_id ORDER BY time DESC) AS rn
    FROM health_metrics
    WHERE bcs IS NOT NULL
)
SELECT a.name, lm.time AS last_check, lm.weight_kg, lm.bcs,
       CASE
           WHEN lm.bcs < 4 THEN 'ИСТОЩЕНИЕ'
           WHEN lm.bcs > 5 THEN 'ОЖИРЕНИЕ'
           ELSE 'НОРМА'
       END AS verdict
FROM latest_metrics lm
JOIN animals a ON a.id = lm.animal_id
WHERE lm.rn = 1;

/* 
   ЗАПРОС 5: Транзакция 
   Цель: Атомарно оформить выздоровление хомяка после аллергического дерматита.
*/
BEGIN;
    UPDATE animals
    SET current_condition = 'health'
    WHERE id = 7
      AND lifecycle_status <> 'deceased';

    INSERT INTO medical_records (animal_id, record_type, diagnosis, treatment, cost)
    VALUES (
        7,
        'exam',
        'Аллергический дерматит в ремиссии',
        'Отмена антигистаминных, контроль кожи через 2 недели',
        500.00
    );
COMMIT;

-- Проверка результата транзакции
SELECT name, current_condition FROM animals WHERE id = 7;