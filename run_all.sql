-- Полный запуск: схема -> справочники -> демо-данные -> аналитика
-- psql -d shelter_db -v ON_ERROR_STOP=1 -f run_all.sql
\i database/schema.sql
\i database/reference_data.sql
\i database/demo_data.sql
\i analytics/analytics_queries.sql
