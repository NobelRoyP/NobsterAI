import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'db_helper.dart';

Future<String> extractTextFromPdf(Uint8List bytes) async {
  try {
    final PdfDocument document = PdfDocument(inputBytes: bytes);
    final extractor = PdfTextExtractor(document);
    final text = extractor.extractText();
    debugPrint('Extracted PDF text length: ${text.length}');
    if (text.length > 100) {
      debugPrint('Extracted PDF text preview: ${text.substring(0, 100)}');
    }
    document.dispose();
    return text;
  } catch (e) {
    debugPrint('PDF text extraction error: $e');
    return '';
  }
}

Future<String> extractTextFromDocx(Uint8List bytes) async {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.files.firstWhere(
      (file) => file.name == 'word/document.xml',
      orElse: () => throw Exception('document.xml not found in DOCX'),
    );
    final xmlString = utf8.decode(documentFile.content as List<int>);
    final document = XmlDocument.parse(xmlString);
    final buffer = StringBuffer();
    for (final node in document.findAllElements('w:t')) {
      buffer.write(node.text);
      buffer.write(' ');
    }
    return buffer.toString();
  } catch (e) {
    debugPrint('DOCX text extraction error: $e');
    return '';
  }
}

void main() {
  runApp(GeminiAppRoot());
}

class GeminiAppRoot extends StatefulWidget {
  const GeminiAppRoot({super.key});

  @override
  State<GeminiAppRoot> createState() => _GeminiAppRootState();
}

class _GeminiAppRootState extends State<GeminiAppRoot> {
  ThemeMode _themeMode = ThemeMode.system;

  void _setThemeMode(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
    _saveThemeMode(mode);
  }

  @override
  void initState() {
    super.initState();
    _loadThemeMode().then((mode) {
      setState(() {
        _themeMode = mode;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return GeminiTheme(
      themeMode: _themeMode,
      setThemeMode: _setThemeMode,
      child: GeminiChatApp(),
    );
  }
}

Future<void> _saveThemeMode(ThemeMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('themeMode', mode.toString());
}

Future<ThemeMode> _loadThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  final modeStr = prefs.getString('themeMode');
  switch (modeStr) {
    case 'ThemeMode.light':
      return ThemeMode.light;
    case 'ThemeMode.dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

class GeminiTheme extends InheritedWidget {
  final ThemeMode themeMode;
  final void Function(ThemeMode) setThemeMode;

  const GeminiTheme({super.key, 
    required this.themeMode,
    required this.setThemeMode,
    required super.child,
  });

  static GeminiTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GeminiTheme>()!;

  @override
  bool updateShouldNotify(GeminiTheme oldWidget) =>
      themeMode != oldWidget.themeMode;
}

class GeminiChatApp extends StatelessWidget {
  const GeminiChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = GeminiTheme.of(context);
    return MaterialApp(
      title: 'Gemini Chatbot',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
      ),
      themeMode: theme.themeMode,
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  FlutterTts flutterTts = FlutterTts();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      await _saveAllConversations();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Save conversations asynchronously but do not await to avoid blocking dispose
    _saveAllConversations();
    super.dispose();
  }

  Future<void> speak(String text) async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setPitch(1.0);
    if (kIsWeb) {
      await flutterTts.setSpeechRate(1.0);
    } else if (Platform.isAndroid || Platform.isWindows) {
      await flutterTts.setSpeechRate(0.5);
    } else {
      await flutterTts.setSpeechRate(0.75);
    }
    await flutterTts.speak(text);
  }

  String? _pendingFileContent;
  String? _pendingFileName;

  final List<String> _allFileContents = [];
  final List<String> _allFileNames = [];

  List<Conversation> _conversations = [];
  int _currentConversationIndex = 0;

  Conversation get _currentConversation {
    if (_conversations.isEmpty) {
      return Conversation(id: const Uuid().v4(), title: "New Chat", messages: []);
    }
    if (_currentConversationIndex < 0 || _currentConversationIndex >= _conversations.length) {
      _currentConversationIndex = _conversations.length - 1;
    }
    return _conversations[_currentConversationIndex];
  }

  final DBHelper _dbHelper = DBHelper();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConversationsFromDB();
  }

  Future<void> _loadConversationsFromDB() async {
    final convMaps = await _dbHelper.getConversations();
    List<Conversation> convs = [];
    for (var convMap in convMaps) {
      final messagesMaps = await _dbHelper.getMessages(convMap['id']);
      final messages = messagesMaps.map((m) => _Message(m['text'], m['is_bot'] == 1, timestamp: m['timestamp'] ?? 0)).toList();
      convs.add(Conversation(id: convMap['id'], title: convMap['title'], messages: messages));
    }
    if (convs.isEmpty) {
      convs.add(Conversation(id: const Uuid().v4(), title: "New Chat", messages: []));
    }
    setState(() {
      _conversations = convs;
      // Set to "New Chat" conversation if exists, else last conversation
      int newChatIndex = convs.indexWhere((c) => c.title == "New Chat");
      if (newChatIndex != -1) {
        _currentConversationIndex = newChatIndex;
      } else {
        _currentConversationIndex = convs.isEmpty ? -1 : convs.length - 1;
      }
    });
  }

  Future<void> _saveConversationToDB(Conversation conv) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await _dbHelper.insertConversation(conv.id, conv.title);
    await _dbHelper.clearMessages(conv.id);
    for (var msg in conv.messages) {
      await _dbHelper.insertMessage(conv.id, msg.text, msg.isBot);
    }
  }

  // Removed override of setState to prevent saving conversations on every UI rebuild
  // Instead, save conversations explicitly when messages or conversations change

  // New method to save all conversations
  Future<void> _saveAllConversations() async {
    if (_conversations.isNotEmpty) {
      for (var conv in _conversations) {
        await _saveConversationToDB(conv);
      }
    }
  }

  Future<void> _sendMessage(String text) async {
    // Ensure at least one "New Chat" exists
    if (!_conversations.any((c) => c.title == "New Chat")) {
      _conversations.add(
        Conversation(id: const Uuid().v4(), title: "New Chat", messages: []),
      );
    }

    if (text.trim().toLowerCase() == "read") {
      text = "Please show me the entire content of the file.";
    }

    String fullText = text;
    String displayText = text;

    if (_pendingFileContent != null) {
      displayText += '\n\n[Attached file: ${_pendingFileName ?? "file.txt"}]';
      // Append the new file content instead of replacing
      _allFileContents.add(_pendingFileContent!);
      _allFileNames.add(_pendingFileName ?? "file.txt");
    } else if (_allFileContents.isEmpty) {
      // If no pending file and no existing context, clear context to avoid stale data
      _allFileContents.clear();
      _allFileNames.clear();
    }

    String contextBlock = '';
    final lowerText = text.toLowerCase();
    final isSummaryRequest = lowerText.contains('summary') || lowerText.contains('extract');

    // Check if user wants to exclude file context by prefixing message with "no file context:"
    bool excludeFileContext = false;
    const excludePrefix = 'no file context:';
    String actualText = text;
    if (lowerText.startsWith(excludePrefix)) {
      excludeFileContext = true;
      actualText = text.substring(excludePrefix.length).trim();
    } else {
      // Also exclude file context if user says phrases like "leave that", "let's talk about something else", etc.
      final excludePhrases = [
        'leave that',
        'let\'s talk about something else',
        'let us talk about something else',
        'ignore the file',
        'don\'t use the file',
        'talk about something else',
        'something else',
        'leave it',
        'forget the file',
        'stop using the file',
        'no more file',
        'no file please',
        'don\'t consider the file',
        'don\'t refer to the file',
        'not about the file',
      ];
      for (final phrase in excludePhrases) {
        if (lowerText.contains(phrase)) {
          excludeFileContext = true;
          break;
        }
      }
    }

    if (!excludeFileContext && contextBlock.isEmpty && _allFileContents.isNotEmpty) {
      if (isSummaryRequest) {
        // Include only the last attached file content for summary/extract requests
        final lastIndex = _allFileContents.length - 1;
        contextBlock =
          'File: ${_allFileNames[lastIndex]}\n'
          '${_allFileContents[lastIndex]}\n\n';
      } else {
        // Include all files for other requests
        for (int i = 0; i < _allFileContents.length; i++) {
          contextBlock +=
            'File: ${_allFileNames[i]}\n'
            '${_allFileContents[i]}\n\n';
        }
      }
    }

    if (contextBlock.isNotEmpty) {
      fullText =
        'CONTEXT (read carefully):\n'
        '$contextBlock\n'
        'QUESTION: $actualText\n\n'
        'INSTRUCTIONS: You MUST answer the QUESTION above using ONLY the CONTEXT provided. '
        'If the answer is not present in the CONTEXT, reply exactly: "Not found in context". '
        'Do NOT say you cannot access files. The CONTEXT is provided above as plain text. '
        'Repeat back the relevant content from CONTEXT if asked to "read" or "summarize".';
    }

    // Check if the user is asking for current date or time
    final dateTimeQueryPatterns = [
      RegExp(r'\bwhat\s+is\s+the\s+current\s+date\b', caseSensitive: false),
      RegExp(r'\bwhat\s+is\s+the\s+current\s+time\b', caseSensitive: false),
      RegExp(r'\bwhat\s+is\s+the\s+date\s+now\b', caseSensitive: false),
      RegExp(r'\bcurrent\s+date\b', caseSensitive: false),
      RegExp(r'\btime\s+date\b', caseSensitive: false),
      RegExp(r'\bdate\s+and\s+time\b', caseSensitive: false),
      RegExp(r'\bwhat\s+is\s+the\s+current\s+time\b', caseSensitive: false),
      RegExp(r'\bdate\s+now\b', caseSensitive: false),
      RegExp(r'\bdate\s+today\b', caseSensitive: false),
      RegExp(r'\bwhat\s+time\s+is\s+it\b', caseSensitive: false),
      RegExp(r'\bcurrent\s+time\b', caseSensitive: false),
      RegExp(r'\btime\s+now\b', caseSensitive: false),
      RegExp(r'\bwhat\s+is\s+the\s+time\b', caseSensitive: false),
    ];

    bool isDateTimeQuery = dateTimeQueryPatterns.any((pattern) => pattern.hasMatch(text));

    final identityRegExp = RegExp(
      r'((who|hu)\s*(are|r)?\s*(you|u))|'
      r'(what\s*(are|r)?\s*(you|u))|'      
      r'(who\s*created\s*you)|'
      r'(who\s*made\s*you)|'
      r'(identify\s*yourself)|'
      r'(who\s*am\s*i\s*talking\s*to)',
      caseSensitive: false,
    );

    if (identityRegExp.hasMatch(fullText.toLowerCase()) == true) {
      // Directly respond with identity phrase without web search or bot call
      final identityResponse = 'I am NOBSTER AI made by Nobel Roy P.';
      setState(() {
        _currentConversation.messages.add(_Message(displayText, false));
        _currentConversation.messages.add(_Message(identityResponse, true));
        _isLoading = false;
      });
      _controller.clear();
      return;
    }

    if (isDateTimeQuery) {
      final now = DateTime.now();
      // Format date as dd/mm/yyyy
      final dateStr = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
      // Format time as hh:mm am/pm
      int hour = now.hour;
      final ampm = hour >= 12 ? 'pm' : 'am';
      hour = hour % 12;
      if (hour == 0) hour = 12;
      final timeStr = '${hour.toString()}:${now.minute.toString().padLeft(2, '0')} $ampm';
      final dateTimeResponse = 'The current date is $dateStr and the time is $timeStr.';

      setState(() {
        _currentConversation.messages.add(_Message(displayText, false));
        _currentConversation.messages.add(_Message(dateTimeResponse, true));
        _isLoading = false;
      });

      _controller.clear();
      return;
    }

    setState(() {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentConversation.messages.add(_Message(displayText, false, timestamp: timestamp));
      _isLoading = true;
      if (_currentConversation.title == "New Chat" && text.trim().isNotEmpty) {
        _currentConversation.title = text.length > 20 ? text.substring(0, 20) : text;
        _dbHelper.updateConversationTitle(_currentConversation.id, _currentConversation.title);
        if (!_conversations.any((c) => c.title == "New Chat")) {
          _conversations.add(
            Conversation(id: const Uuid().v4(), title: "New Chat", messages: []),
          );
        }
      }
    });
    _controller.clear();
    _focusNode.requestFocus();

    // Only clear the pending file after sending
    _pendingFileContent = null;
    _pendingFileName = null;

    // Clear file context if this is not a summary/extract request
    // Disabled clearing to preserve file context across multiple questions
    // if (!isSummaryRequest) {
    //   _allFileContents.clear();
    //   _allFileNames.clear();
    // }

    // Use fullText for web search and reply
    List<Map<String, String>> searchResults = [];
    bool doWebSearch = _needsWebSearch(fullText);
    if (doWebSearch) {
      searchResults = await _googleSearch(fullText);
    }

    final reply = await _getGeminiReply(fullText, doWebSearch ? searchResults : []);

    // Add a delay before showing the bot's reply
    await Future.delayed(const Duration(milliseconds: 900));

    setState(() {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentConversation.messages.add(_Message(reply, true, timestamp: timestamp));
      _isLoading = false;
    });
    _saveConversationToDB(_currentConversation);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<String> _getGeminiReply(String prompt, List<Map<String, String>> webResults) async {
    const apiKey = 'AIzaSyBCTBJP0yYWNRVCfx-AdgjyBPYUYLSy5fs';
    const endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$apiKey';

    String webContext = '';
    if (webResults.isNotEmpty) {
      webContext = 'Web search results:\n';
      for (var r in webResults) {
        webContext += '${r['title']}\n${r['snippet']}\nLink: ${r['link']}\n\n';
      }
      // Relaxed instruction to allow bot to answer from conversation context if web results do not contain answer
      webContext +=
          'Using the web search results above, answer the user query with up-to-date information. ' 
          'If you use a web result, cite the link in your answer. '
          'Answer the question directly and do not say you are using web search results. '
          'If the web results do not contain the answer, you may answer based on your knowledge and the conversation context. '
          'Do not make up information not supported by the web results or conversation context.\n';
    }

    // Limit to last 20 messages to avoid request size issues
    final recentMessages = _currentConversation.messages.where((msg) => msg.text.trim().isNotEmpty).toList();
    final limitedMessages = recentMessages.length > 20 ? recentMessages.sublist(recentMessages.length - 20) : recentMessages;

    final List<Map<String, dynamic>> contents = [
      // Add webContext as a system message if present
      if (webContext.isNotEmpty)
        {
          'role': 'user',
          'parts': [{'text': webContext}]
        },
      // Removed identity instruction message to prevent forced identity phrase in bot response
      ...limitedMessages.map((msg) => {
        'role': msg.isBot ? 'model' : 'user',
        'parts': [{'text': msg.text}]
      }),
      // Always add the latest prompt as the last user message
      {
        'role': 'user',
        'parts': [{'text': prompt}]
      },
    ];



    try {
      final response = await http
          .post(
            Uri.parse(endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'contents': contents}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'];
        return text ?? 'No response';
      } else {
        debugPrint('Gemini API error response: ${response.body}');
        return 'Error: ${response.statusCode}';
      }
    } on http.ClientException catch (e) {
      debugPrint('Gemini API ClientException: $e');
      return 'Currently you are offline.';
    } on SocketException catch (e) {
      debugPrint('Gemini API SocketException: $e');
      return 'Currently you are offline.';
    } on TimeoutException catch (e) {
      debugPrint('Gemini API TimeoutException: $e');
      return 'Error: $e';
    } catch (e) {
      debugPrint('Gemini API unknown error: $e');
      return 'Error: $e';
    }
  }

  Future<List<Map<String, String>>> _googleSearch(String query) async {
    if (query.trim().isEmpty) {
      debugPrint('Google Custom Search API: Empty query, skipping search.');
      return [];
    }
    const apiKey = 'AIzaSyDMctB0qNS3pAagmzI2RDGMPHf223LRygQ';
    const cseId = '624ab5887e8ab4b2f';
    final url =
        'https://www.googleapis.com/customsearch/v1?key=$apiKey&cx=$cseId&q=${Uri.encodeQueryComponent(query)}';

    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final items = data['items'] as List?;
        if (items == null) return [];
        return items.take(3).map<Map<String, String>>((item) {
          return {
            'title': item['title'],
            'link': item['link'],
            'snippet': item['snippet'] ?? '',
          };
        }).toList();
      } else {
        debugPrint('Google Custom Search API error response: ${response.statusCode} ${response.body}');
        return [];
      }
    } on http.ClientException catch (e) {
      debugPrint('Google Custom Search API ClientException: $e');
      return [
        {
          'title': 'Offline',
          'link': '',
          'snippet': 'Currently you are offline.'
        }
      ];
    } on SocketException catch (e) {
      debugPrint('Google Custom Search API SocketException: $e');
      return [
        {
          'title': 'Offline',
          'link': '',
          'snippet': 'Currently you are offline.'
        }
      ];
    } on TimeoutException catch (e) {
      debugPrint('Google Custom Search API TimeoutException: $e');
      return [
        {
          'title': 'Offline',
          'link': '',
          'snippet': 'Currently you are offline.'
        }
      ];
    } catch (e) {
      debugPrint('Google Custom Search API unknown error: $e');
      return [];
    }
  }

  bool _needsWebSearch(String text) {
  final lower = text.toLowerCase();
  // Only trigger web search for news/current events/factual queries
  return [
    'news', 'latest', 'current', 'happening', 'update', 'today', 'recent',
    'who', 'what', 'when', 'where', 'why', 'how', 'president', 'prime minister', 'capital', 'population',
    'weather', 'stock', 'price', 'exchange', 'breaking', 'live', 'real-time', 'real time', 'sports', 'score'
  ].any((kw) => lower.contains(kw));
}

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }

  void _switchConversation(int index) {
    setState(() {
      // Map index in drawer list to internal _conversations index
      final newChatIndex = _conversations.indexWhere((c) => c.title == "New Chat");
      int internalIndex;
      if (newChatIndex == -1) {
        internalIndex = index;
      } else {
        // "New Chat" is at the top of the drawer list
        if (index == 0) {
          internalIndex = newChatIndex;
        } else {
          // Others are sorted below, so map index to others
          // Build list of others excluding "New Chat"
          final others = List<Conversation>.from(_conversations);
          others.removeAt(newChatIndex);
          // Sort others by last message timestamp descending (newest first)
          others.sort((a, b) {
            int aTimestamp = a.messages.isNotEmpty ? a.messages.last.timestamp : 0;
            int bTimestamp = b.messages.isNotEmpty ? b.messages.last.timestamp : 0;
            return bTimestamp.compareTo(aTimestamp);
          });
          final conv = others[index - 1];
          internalIndex = _conversations.indexOf(conv);
        }
      }
      _currentConversationIndex = internalIndex;
      // Clear file context when switching conversations
      _allFileContents.clear();
      _allFileNames.clear();
      _pendingFileContent = null;
      _pendingFileName = null;
    });
    Navigator.pop(context); // close drawer
  }

// Optional: Place this outside the widget class for reuse
String _decodeTextFile(Uint8List bytes) {
  try {
    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }

    // UTF-16 LE BOM
    if (bytes.length >= 2 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xFE) {
      final byteData = ByteData.sublistView(bytes.sublist(2));
      final codeUnits = List.generate(
        byteData.lengthInBytes ~/ 2,
        (i) => byteData.getUint16(i * 2, Endian.little),
      );
      return String.fromCharCodes(codeUnits);
    }

    // UTF-16 BE BOM
    if (bytes.length >= 2 &&
        bytes[0] == 0xFE &&
        bytes[1] == 0xFF) {
      final byteData = ByteData.sublistView(bytes.sublist(2));
      final codeUnits = List.generate(
        byteData.lengthInBytes ~/ 2,
        (i) => byteData.getUint16(i * 2, Endian.big),
      );
      return String.fromCharCodes(codeUnits);
    }

    // Default to UTF-8
    return utf8.decode(bytes);
  } catch (e) {
    return latin1.decode(bytes);
  }
}

  Future<void> _pickAndAttachFile() async {
    const typeGroup = XTypeGroup(
      label: 'documents',
      extensions: ['txt', 'pdf', 'docx', 'pptx', 'xlsx'],
    );

    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    String fileContent = '';
    final parts = file.name.split('.');
    if (parts.length < 2) {
      _showSnackBar('File must have an extension.');
      return;
    }

    String ext = parts.last.toLowerCase();
    Uint8List bytes = await file.readAsBytes();

    try {
      if (ext == 'txt') {
        fileContent = _decodeTextFile(bytes);
      } else if (ext == 'pdf') {
        try {
          fileContent = await extractTextFromPdf(bytes);
          debugPrint('PDF file content length: ${fileContent.length}');
          if (fileContent.length > 100) {
            debugPrint('PDF file content preview: ${fileContent.substring(0, 100)}');
          }
        } catch (e) {
          debugPrint('Error extracting text: $e');
          debugPrintStack(stackTrace: StackTrace.current);
          _showSnackBar('File could not be read or extracted. Error: $e');
          return;
        }
      } else if (ext == 'docx') {
        try {
          fileContent = await extractTextFromDocx(bytes);
          if (fileContent.trim().isEmpty) {
            _showSnackBar('DOCX file is empty or could not be read.');
            return;
          }
        } catch (e) {
          debugPrint('Error extracting text from DOCX: $e');
          _showSnackBar('File could not be read or extracted. Error: $e');
          return;
        }
      } else {
        _showSnackBar('Unsupported file type.');
        return;
      }
    } catch (e) {
      debugPrint('Error reading file: $e');
      _showSnackBar('File could not be read or extracted.');
      return;
    }

    if (fileContent.trim().isEmpty) {
      _showSnackBar('File is empty or could not be read.');
      return;
    }

    const int maxContentLength = 4000;
    if (fileContent.length > maxContentLength) {
      fileContent = fileContent.substring(0, maxContentLength);
    }

    setState(() {
      _pendingFileContent = fileContent;
      _pendingFileName = file.name;
      _allFileContents.add(fileContent); // assuming this is a List<String>
      _allFileNames.add(file.name);      // assuming this is a List<String>
      _showSnackBar('File "${_pendingFileName!}" attached. It will be sent with your next message.');
    });
  }


  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentConversation.title),
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                _openSettings();
              },
            ),
            const Divider(),
            ...(() {
              // Separate "New Chat" conversation and others
              final newChatIndex = _conversations.indexWhere((c) => c.title == "New Chat");
              final List<Conversation> others = List.from(_conversations);
              Conversation? newChatConv;
              if (newChatIndex != -1) {
                newChatConv = others.removeAt(newChatIndex);
              }
              // Sort others by last message timestamp descending (newest first)
              others.sort((a, b) {
                int aTimestamp = a.messages.isNotEmpty ? a.messages.last.timestamp : 0;
                int bTimestamp = b.messages.isNotEmpty ? b.messages.last.timestamp : 0;
                return bTimestamp.compareTo(aTimestamp);
              });
              // Build list with "New Chat" first, then others
              final List<Conversation> orderedConvs = [];
              if (newChatConv != null) {
                orderedConvs.add(newChatConv);
              }
              orderedConvs.addAll(others);
              return orderedConvs.asMap().entries.expand<Widget>((entry) {
                final idx = entry.key;
                final conv = entry.value;
                // Map idx to internal index in _conversations
                final internalIndex = _conversations.indexOf(conv);
                return [
                  ListTile(
                    leading: Icon(
                      conv.title == "New Chat" ? Icons.add : Icons.chat_bubble,
                      color: internalIndex == _currentConversationIndex ? Colors.blue : null,
                    ),
                    title: Text(conv.title, overflow: TextOverflow.ellipsis),
                    selected: internalIndex == _currentConversationIndex,
                    onTap: () => _switchConversation(idx),
                    trailing: conv.messages.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.delete, size: 20, color: Colors.redAccent),
                            tooltip: 'Delete conversation',
                            onPressed: () async {
                              await _dbHelper.deleteConversation(_conversations[internalIndex].id);
                              setState(() {
                                _conversations.removeAt(internalIndex);
                                if (_conversations.isEmpty) {
                                  _conversations.add(
                                    Conversation(id: const Uuid().v4(), title: "New Chat", messages: []),
                                  );
                                  _currentConversationIndex = 0;
                                } else if (_currentConversationIndex >= _conversations.length) {
                                  _currentConversationIndex = _conversations.length - 1;
                                }
                              });
                              Navigator.pop(context);
                            },
                          )
                        : null,
                  ),
                ];
              }).toList();
            })(),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _currentConversation.messages.length,
              itemBuilder: (context, index) {
                final messages = _currentConversation.messages;
                final msg = messages[index];
                return ListTile(
                  title: Align(
                    alignment: msg.isBot ? Alignment.centerLeft : Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (msg.text.length > 100 || MediaQuery.of(context).size.width < 600)
                            ? MediaQuery.of(context).size.width * 0.95
                            : MediaQuery.of(context).size.width * 0.7,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: msg.isBot
                              ? Theme.of(context).brightness == Brightness.dark
                                  ? Colors.grey[800]
                                  : Colors.grey[300]
                              : Theme.of(context).brightness == Brightness.dark
                                  ? Colors.blue[900]
                                  : Colors.blue[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                      child: buildMessageText(msg.text, context, msg.isBot),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Show attached file name just above the input row
          if (_pendingFileContent != null && _pendingFileName != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4, top: 4),
              child: Row(
                children: [
                  const Icon(Icons.attach_file, size: 20),
                  Expanded(
                    child: Text(
                      _pendingFileName!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove attached file',
                    onPressed: () {
                      setState(() {
                        _pendingFileContent = null;
                        _pendingFileName = null;
                      });
                    },
                  ),
                ],
              ),
            ),
          if (_isLoading) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width > 600 ? 500 : double.infinity,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // File upload button to the left
                    Container(
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.attach_file, color: Colors.white),
                        tooltip: 'Attach file to next message',
                        onPressed: _pickAndAttachFile,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withAlpha(
                            (Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.9) * 255 ~/ 1,
                          ),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Center(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            onSubmitted: _sendMessage,
                            minLines: 1,
                            maxLines: 1,
                            decoration: const InputDecoration(
                              hintText: 'Type your message...',
                              border: InputBorder.none,
                              isCollapsed: true,
                            ),
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: Colors.white),
                        onPressed: _isLoading
                            ? null
                            : () {
                                if (_controller.text.trim().isNotEmpty) {
                                  _sendMessage(_controller.text.trim());
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget buildMessageText(String text, BuildContext context, bool isBot) {
  final screenWidth = MediaQuery.of(context).size.width;
  final isLongMessage = text.length > 100;
  final maxBubbleWidth = isLongMessage || screenWidth < 600 ? screenWidth * 0.95 : screenWidth * 0.7;

  return Container(
    constraints: BoxConstraints(
      maxWidth: maxBubbleWidth,
    ),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: isBot
          ? Theme.of(context).brightness == Brightness.dark
              ? Colors.grey[800]
              : Colors.grey[300]
          : Theme.of(context).brightness == Brightness.dark
              ? Colors.blue[900]
              : Colors.blue[100],
      borderRadius: BorderRadius.circular(8),
    ),
    child: Stack(
      children: [
        Padding(
          padding: isBot ? const EdgeInsets.only(top: 28) : EdgeInsets.zero,
          child: MarkdownBody(
            data: text,
            onTapLink: (text, href, title) async {
              if (href != null) {
                try {
                  await launchUrl(
                    Uri.parse(href),
                    mode: LaunchMode.platformDefault,
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open the link.')),
                  );
                }
              }
            },
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
          ),
        ),
        if (isBot)
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[900]
                    : Colors.white,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.volume_up, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  context.findAncestorStateOfType<_ChatScreenState>()!.speak(text);
                },
              ),
            ),
          ),
      ],
    ),
  );
}

class _Message {
  final String text;
  final bool isBot;
  final int timestamp;
  _Message(this.text, this.isBot, {this.timestamp = 0});

  Map<String, dynamic> toJson() => {'text': text, 'isBot': isBot, 'timestamp': timestamp};
  factory _Message.fromJson(Map<String, dynamic> json) =>
      _Message(json['text'], json['isBot'], timestamp: json['timestamp'] ?? 0);
}

class Conversation {
  final String id;
  String title;
  final List<_Message> messages;

  Conversation({required this.id, required this.title, required this.messages});

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'],
    title: json['title'],
    messages: (json['messages'] as List)
        .map((m) => _Message.fromJson(m))
        .toList(),
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = GeminiTheme.of(context);
    ThemeMode currentMode = theme.themeMode;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Theme'),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('System Default'),
            value: ThemeMode.system,
            groupValue: currentMode,
            onChanged: (mode) {
              theme.setThemeMode(mode!);
            },
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Light'),
            value: ThemeMode.light,
            groupValue: currentMode,
            onChanged: (mode) {
              theme.setThemeMode(mode!);
            },
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Dark'),
            value: ThemeMode.dark,
            groupValue: currentMode,
            onChanged: (mode) {
              theme.setThemeMode(mode!);
            },
          ),
        ],
      ),
    );
  }
}

class ConversationHistoryScreen extends StatelessWidget {
  final List<_Message> messages;
  const ConversationHistoryScreen({super.key, required this.messages});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation History')),
      body: ListView.builder(
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final msg = messages[index];
          return ListTile(
            leading: Icon(msg.isBot ? Icons.smart_toy : Icons.person),
            title: Text(msg.text),
            subtitle: Text(msg.isBot ? 'Bot' : 'You'),
          );
        },
      ),
    );
  }
}
