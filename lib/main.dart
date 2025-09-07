import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/notification_service.dart';

import 'main_tabs_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('budgetBox');
  await NotificationService().init();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool? isSignedIn; // null = loading

  @override
  void initState() {
    super.initState();
    checkSignInStatus();
  }

  Future<void> checkSignInStatus() async {
    final GoogleSignIn googleSignIn = GoogleSignIn();
    try {
      final account = await googleSignIn.signInSilently();
      setState(() {
        isSignedIn = account != null;
      });
    } catch (e) {
      // If silent sign-in fails, assume user is signed out
      setState(() {
        isSignedIn = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4B6A6A)),
        scaffoldBackgroundColor: const Color(0xFFF5F6F8),
        appBarTheme: const AppBarTheme(centerTitle: true),
        navigationBarTheme: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            );
          }),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 1,
          margin: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),

      home: isSignedIn == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : isSignedIn!
          ? const MainTabsPage()
          : LoginPage(
              onSignIn: () {
                setState(() {
                  isSignedIn = true;
                });
              },
            ),
    );
  }
}

class LoginPage extends StatelessWidget {
  final VoidCallback onSignIn;

  const LoginPage({super.key, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.surfaceContainerHighest, cs.primaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Image.asset('assets/app_logo.png', height: 80),
                ),
                const SizedBox(height: 24),
                Text(
                  'BudgetBuddy',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 32),
                // Google Sign-In style per recipe
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 20,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.black.withOpacity(0.1)),
                    ),
                  ),
                  onPressed: () async {
                    final GoogleSignIn googleSignIn = GoogleSignIn();
                    try {
                      final account = await googleSignIn.signIn();
                      if (account != null) {
                        onSignIn();
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Google Sign-In failed: $e')),
                      );
                    }
                  },
                  icon: Image.asset('assets/g-logo.png', height: 20),
                  label: const Text('Sign in with Google'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
