import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleTheme() {
    setState(() {
      if (_themeMode == ThemeMode.light) {
        _themeMode = ThemeMode.dark;
      } else if (_themeMode == ThemeMode.dark) {
        _themeMode = ThemeMode.system;
      } else {
        _themeMode = ThemeMode.light;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '本地AI助手',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: _themeMode,
      home: ChatScreen(onToggleTheme: _toggleTheme, currentThemeMode: _themeMode),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatMessage {
  final String content;
  final bool isUser;
  final DateTime timestamp;
  final String? id;

  ChatMessage({
    required this.content,
    required this.isUser,
    DateTime? timestamp,
    this.id,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'isUser': isUser,
      'timestamp': timestamp.toIso8601String(),
      'id': id,
    };
  }

  static ChatMessage fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      content: json['content'],
      isUser: json['isUser'],
      timestamp: DateTime.parse(json['timestamp']),
      id: json['id'],
    );
  }
}

class ChatScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final ThemeMode currentThemeMode;

  const ChatScreen({
    super.key,
    required this.onToggleTheme,
    required this.currentThemeMode,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _showClearDialog = false;

  // 你的Llama.cpp服务器地址
  final String _apiUrl = 'http://182.92.202.75:5555/v1/chat/completions';

  @override
  void initState() {
    super.initState();
    _loadChatHistory();
  }

  Future<void> _loadChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? chatJson = prefs.getString('chat_history');
      if (chatJson != null) {
        final List<dynamic> jsonList = json.decode(chatJson);
        setState(() {
          _messages.clear();
          _messages.addAll(jsonList.map((json) => ChatMessage.fromJson(json)));
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('加载聊天历史失败: $e');
    }
  }

  Future<void> _saveChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> jsonList =
          _messages.map((msg) => msg.toJson()).toList();
      await prefs.setString('chat_history', json.encode(jsonList));
    } catch (e) {
      debugPrint('保存聊天历史失败: $e');
    }
  }

  Future<void> _sendMessage(String message) async {
    if (message.trim().isEmpty || _isLoading) return;

    // 添加用户消息
    setState(() {
      _messages.add(ChatMessage(
        content: message,
        isUser: true,
        id: DateTime.now().millisecondsSinceEpoch.toString(),
      ));
      _isLoading = true;
    });

    _textController.clear();
    _scrollToBottom();
    await _saveChatHistory();

    try {
      // 构建符合OpenAI兼容格式的请求
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'model': 'qwen',
          'messages': [
            {'role': 'user', 'content': message}
          ],
          'temperature': 0.7,
          'max_tokens': 1024,
          'stream': false,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final aiResponse = data['choices'][0]['message']['content'];

        setState(() {
          _messages.add(ChatMessage(
            content: aiResponse.trim(),
            isUser: false,
            id: DateTime.now().millisecondsSinceEpoch.toString(),
          ));
        });
      } else {
        setState(() {
          _messages.add(ChatMessage(
            content: '**错误**: 服务器返回状态码 ${response.statusCode}\n\n请检查服务器是否正常运行。',
            isUser: false,
            id: DateTime.now().millisecondsSinceEpoch.toString(),
          ));
        });
      }
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          content: '**连接失败**: 请确保Llama.cpp服务器正在运行\n\n**错误详情**: $e',
          isUser: false,
          id: DateTime.now().millisecondsSinceEpoch.toString(),
        ));
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
      _scrollToBottom();
      await _saveChatHistory();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyMessage(String content) {
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('消息已复制到剪贴板'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _deleteMessage(String id) {
    setState(() {
      _messages.removeWhere((msg) => msg.id == id);
    });
    _saveChatHistory();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('消息已删除'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _clearAllMessages() async {
    setState(() {
      _messages.clear();
      _showClearDialog = false;
    });
    await _saveChatHistory();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('聊天记录已清空'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地Qwen助手'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(
              widget.currentThemeMode == ThemeMode.light
                  ? Icons.dark_mode
                  : widget.currentThemeMode == ThemeMode.dark
                      ? Icons.light_mode
                      : Icons.brightness_auto,
            ),
            onPressed: widget.onToggleTheme,
            tooltip: '切换主题',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _messages.isEmpty
                ? null
                : () {
                    setState(() {
                      _showClearDialog = true;
                    });
                  },
            tooltip: '清空聊天记录',
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 消息列表
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    return _buildMessageBubble(message);
                  },
                ),
              ),

              // 加载指示器
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(strokeWidth: 2),
                      SizedBox(width: 12),
                      Text('正在思考...'),
                    ],
                  ),
                ),

              // 输入区域
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: const InputDecoration(
                          hintText: '输入消息...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        onSubmitted: (value) {
                          // 按Enter发送，Shift+Enter换行
                          if (!HardwareKeyboard.instance.isShiftPressed) {
                            _sendMessage(value);
                          }
                        },
                        enabled: !_isLoading,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _isLoading
                          ? null
                          : () => _sendMessage(_textController.text),
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // 清空确认对话框
          if (_showClearDialog)
            AlertDialog(
              title: const Text('确认清空'),
              content: const Text('确定要清空所有聊天记录吗？此操作不可撤销。'),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showClearDialog = false;
                    });
                  },
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: _clearAllMessages,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                  child: const Text('清空'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!message.isUser)
            const CircleAvatar(
              radius: 16,
              child: Icon(Icons.smart_toy),
            ),
          if (!message.isUser) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: message.isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'copy') {
                      _copyMessage(message.content);
                    } else if (value == 'delete') {
                      _deleteMessage(message.id!);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: Row(
                        children: [
                          Icon(Icons.copy, size: 18),
                          SizedBox(width: 8),
                          Text('复制'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 18, color: Colors.red),
                          SizedBox(width: 8),
                          Text('删除', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: message.isUser
                          ? Theme.of(context).primaryColor
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 2,
                          offset: Offset(1, 1),
                        ),
                      ],
                    ),
                    child: MarkdownBody(
                      data: message.content,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).textTheme.bodyLarge?.color,
                          fontSize: 16,
                        ),
                        code: TextStyle(
                          backgroundColor: message.isUser
                              ? Colors.white.withOpacity(0.2)
                              : Colors.grey.withOpacity(0.2),
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: message.isUser
                              ? Colors.white.withOpacity(0.15)
                              : Colors.grey.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        h1: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).textTheme.headlineSmall?.color,
                        ),
                        h2: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).textTheme.titleLarge?.color,
                        ),
                        h3: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).textTheme.titleMedium?.color,
                        ),
                        listBullet: TextStyle(
                          color: message.isUser
                              ? Colors.white
                              : Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                        // link: TextStyle(
                        //   color: message.isUser ? Colors.yellow : Colors.blue,
                        //   decoration: TextDecoration.underline,
                        // ),
                      ),
                      onTapLink: (text, href, title) async {
                        if (href != null) {
                          final uri = Uri.parse(href);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri);
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          if (message.isUser) const SizedBox(width: 8),
          if (message.isUser)
            const CircleAvatar(
              radius: 16,
              child: Icon(Icons.person),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
