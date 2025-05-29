# NobsterAI

This project is a Flutter application that implements a chatbot using the Google Gemini API. The chatbot allows users to send messages and receive responses in a chat interface.

## Features

- User-friendly chat interface
- Integration with Google Gemini API for intelligent responses
- Message formatting and timestamping
- Customizable chat bubbles for user and bot messages

## Project Structure

```
flutter_gemini_chatbot
├── lib
│   ├── main.dart                # Entry point of the application
│   ├── models
│   │   └── message.dart         # Message model representing chat messages
│   ├── screens
│   │   └── chat_screen.dart     # Chat screen displaying the chat interface
│   ├── services
│   │   └── gemini_api_service.dart # Service for communicating with the Gemini API
│   └── widgets
│       └── chat_bubble.dart     # Widget for displaying individual chat messages
├── pubspec.yaml                 # Project configuration and dependencies
└── README.md                    # Project documentation
```

## Setup Instructions

1. Clone the repository:
   ```
   git clone <repository-url>
   ```

2. Navigate to the project directory:
   ```
   cd flutter_gemini_chatbot
   ```

3. Install the dependencies:
   ```
   flutter pub get
   ```

4. Run the application:
   ```
   flutter run
   ```

## Usage

- Open the app and start chatting with the bot.
- Type your message in the input field and press send.
- The bot will respond using the Google Gemini API.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request for any enhancements or bug fixes.