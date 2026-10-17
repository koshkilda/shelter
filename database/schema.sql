-- Удаляем старые объекты, если они есть (для чистого запуска)
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
DROP TABLE IF EXISTS breeds_dict CASCADE;
DROP TABLE IF EXISTS species_dict CASCADE;

-- ============================================================================
-- СПРАВОЧНЫЕ ТАБЛИЦЫ
-- ============================================================================

-- 0.1. Справочник видов животных
CREATE TABLE species_dict (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(20) UNIQUE NOT NULL, -- 'cat', 'dog', 'hamster'
    name_ru     VARCHAR(50)  NOT NULL        -- 'Кошка', 'Собака', 'Хомяк'
);

-- 0.2. Справочник пород
CREATE TABLE breeds_dict (
    id              SERIAL PRIMARY KEY,
    species_id      INT           NOT NULL REFERENCES species_dict(id),
    name            VARCHAR(100)  NOT NULL,     
    predisposition_notes TEXT                    
);

-- ============================================================================
-- ОСНОВНЫЕ СУЩНОСТИ ПРИЮТА
-- ============================================================================

-- 1. Сущность: Животные
CREATE TABLE animals (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    
    -- Ссылка на справочник вместо текстового поля
    species_id      INT           NOT NULL REFERENCES species_dict(id),
    breed_id        INT           REFERENCES breeds_dict(id),
    
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
    category    VARCHAR(50)  NOT NULL, -- 'food', 'medicine', 'equipment', 'consumable'
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
    reference_table VARCHAR(50),  
    reference_id    INT,          
    moved_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- 7. Процесс усыновления: Владельцы
CREATE TABLE owners (
    id          SERIAL PRIMARY KEY,
    full_name   VARCHAR(150) NOT NULL,
    phone       VARCHAR(20),
    email       VARCHAR(100),
    address     TEXT
);

-- 8. Процесс усыновления: История передач
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
CREATE INDEX idx_breeds_species ON breeds_dict(species_id);

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
