from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate

db = SQLAlchemy()
migrate = Migrate()


def _ensure_columns(app):
    """Add any missing columns to existing tables.
    db.create_all() only creates new tables — it won't ALTER existing ones.
    This helper bridges the gap so new model columns are added automatically."""
    from sqlalchemy import inspect as sa_inspect, text

    with db.engine.connect() as conn:
        inspector = sa_inspect(db.engine)
        # (table, column, column_sql) — column_sql uses the DB's native type
        needed = [
            ("fame_entries", "tag", "VARCHAR(64)"),
        ]
        for table, column, col_type in needed:
            if table in inspector.get_table_names():
                existing = {c["name"] for c in inspector.get_columns(table)}
                if column not in existing:
                    conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}"))
                    conn.commit()
                    app.logger.info("Added missing column %s.%s", table, column)


def init_db(app):
    """Initialize database and migrations with the Flask app."""
    db.init_app(app)
    migrate.init_app(app, db)

    with app.app_context():
        # Import models so they're registered with SQLAlchemy
        import models  # noqa: F401

        # Create any new tables that don't exist yet.
        # This works alongside Flask-Migrate — existing tables are untouched,
        # only missing ones are created.
        db.create_all()

        # Add any columns that were added to models after the table was created
        _ensure_columns(app)
