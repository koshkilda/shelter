-- ----------------------------------------------------------------------------
-- АНАЛИТИЧЕСКИЕ ЗАПРОСЫ
-- ----------------------------------------------------------------------------

/* 
   ЗАПРОС 1: JOIN
   Цель: Показать медицинские события вместе с именами животных.
*/
SELECT a.name, sd.name_ru as species_name, m.record_type, m.diagnosis, m.treatment
FROM animals a
JOIN species_dict sd ON sd.id = a.species_id
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
   ВАЖНО: Этот запрос изменяет данные. Выполнять осторожно!
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
