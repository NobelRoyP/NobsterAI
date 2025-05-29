import 'dart:async';
import 'dart:io' show Platform;
import 'package:path/path.dart';

// Import sqflite_common_ffi for Windows desktop support
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DBHelper {
  static final DBHelper _instance = DBHelper._internal();
  factory DBHelper() => _instance;
  DBHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('chat_history.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    // Initialize sqflite ffi for Windows desktop
    if (Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    // Print the database path for debugging
    print('Database path: $path');

    final db = await openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );

    // Enable foreign key constraints
    await db.execute('PRAGMA foreign_keys = ON;');

    return db;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add last_updated column to conversations table
      await db.execute('ALTER TABLE conversations ADD COLUMN last_updated INTEGER');
      // Optionally, update existing rows with current timestamp
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await db.execute('UPDATE conversations SET last_updated = ?', [timestamp]);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE messages ADD COLUMN timestamp INTEGER');
    }
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT,
        last_updated INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT,
        text TEXT,
        is_bot INTEGER,
        timestamp INTEGER,
        FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> insertConversation(String id, String title) async {
    final db = await database;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'conversations',
      {'id': id, 'title': title, 'last_updated': timestamp},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateConversationTitle(String id, String title) async {
    final db = await database;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'conversations',
      {'title': title, 'last_updated': timestamp},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteConversation(String id) async {
    final db = await database;
    await db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertMessage(String conversationId, String text, bool isBot) async {
    final db = await database;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'messages',
      {
        'conversation_id': conversationId,
        'text': text,
        'is_bot': isBot ? 1 : 0,
        'timestamp': timestamp,
      },
    );
  }

  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await database;
    return await db.query('conversations', orderBy: 'last_updated DESC');
  }

  Future<List<Map<String, dynamic>>> getMessages(String conversationId) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<void> clearMessages(String conversationId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }
}
