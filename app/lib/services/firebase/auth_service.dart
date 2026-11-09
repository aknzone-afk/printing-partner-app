import 'package:firebase_auth/firebase_auth.dart';

/// Anonymous auth (owner 9-Nov-2026 — same model as the B.B Synthetics app,
/// NO OTP). Every customer gets a silent anonymous uid so Firestore order
/// writes pass the security rules. The real identity is the mobile number the
/// customer types on the address form.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  String? get uid => _auth.currentUser?.uid;
  bool get isLoggedIn => _auth.currentUser != null;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Signs in anonymously if there is no user yet. Safe to call repeatedly —
  /// it signs in only when there is no current user.
  Future<String?> ensureSignedIn() async {
    if (_auth.currentUser != null) return _auth.currentUser!.uid;
    final cred = await _auth.signInAnonymously();
    return cred.user?.uid;
  }

  Future<void> signOut() => _auth.signOut();
}
