// A catalog shaped like core's plus the ebooks plugin's tables, for the store tests.
import Database from 'better-sqlite3';

export function seeded({ webProgress = true } = {}) {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE series (id INTEGER PRIMARY KEY, title TEXT, url TEXT, publisher TEXT, type TEXT DEFAULT 'comic', library_id INTEGER, restricted INTEGER DEFAULT 0, description TEXT DEFAULT NULL);
    CREATE TABLE issues (id INTEGER PRIMARY KEY, series_id INTEGER, title TEXT, issue_number TEXT);
    CREATE TABLE libraries (id INTEGER PRIMARY KEY, name TEXT, type TEXT);
    CREATE TABLE ebooks_files (path TEXT, library_id INTEGER, series_id INTEGER, issue_id INTEGER, format TEXT, size INTEGER, mtime INTEGER, source TEXT, remote_id TEXT, added_at TEXT);
    INSERT INTO libraries VALUES (1,'Fiction','ebook'),(3,'Adult','ebook');
    INSERT INTO series (id,title,url,publisher,type,library_id,restricted) VALUES (10,'Dune','ebook:l1:b:dune~herbert','Frank Herbert','ebook',1,0);
    INSERT INTO issues VALUES (100,10,'Dune','1');
    INSERT INTO ebooks_files VALUES ('/lib/dune.epub',1,10,100,'epub',500000,1000,NULL,NULL,'2026-01-01T00:00:00Z');
    INSERT INTO series (id,title,url,publisher,type,library_id,restricted) VALUES (11,'Discworld','ebook:l1:s:discworld','Terry Pratchett','ebook',1,0);
    INSERT INTO issues VALUES (101,11,'Mort','4'),(102,11,'Guards! Guards!','8');
    INSERT INTO ebooks_files VALUES ('/lib/mort.pdf',1,11,101,'pdf',900000,2000,NULL,NULL,'2026-02-01T00:00:00Z');
    INSERT INTO ebooks_files VALUES (NULL,1,11,102,'epub',NULL,NULL,'warehouse','g8',  '2026-03-01T00:00:00Z');
    INSERT INTO series (id,title,url,publisher,type,library_id,restricted) VALUES (12,'Secret','ebook:l3:b:secret','Anon','ebook',3,1);
    INSERT INTO issues VALUES (103,12,'Secret','1');
    INSERT INTO ebooks_files VALUES ('/adult/secret.epub',3,12,103,'epub',1000,3000,NULL,NULL,'2026-04-01T00:00:00Z');
    INSERT INTO series (id,title,url,publisher,type,library_id,restricted) VALUES (20,'Batman','cv:1','DC','comic',2,0);
    INSERT INTO issues VALUES (200,20,'Batman #1','1');
  `);
  if (webProgress) {
    db.exec(`CREATE TABLE ebooks_progress (user_id INTEGER NOT NULL DEFAULT 0, issue_id INTEGER NOT NULL, locator TEXT,
      fraction REAL NOT NULL DEFAULT 0, updated_at TEXT, chapter TEXT, page INTEGER, pages INTEGER, PRIMARY KEY (user_id, issue_id));
      CREATE TABLE ebooks_bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL DEFAULT 0, issue_id INTEGER NOT NULL,
      locator TEXT NOT NULL, fraction REAL NOT NULL DEFAULT 0, note TEXT, created_at TEXT, color TEXT, text TEXT);`);
  }
  return db;
}
