-- Схемы: raw — файлы как есть (всё текстом), clean — типы и очистка, mart — витрины, qa — качество данных.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS rules;
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS qa;
