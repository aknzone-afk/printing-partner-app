import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Phone-OTP authentication + the signed-in user's Firestore profile.
///
/// SPARK MODE: there are no Cloud Functions, so the client upserts its own
/// `users/{uid}` doc after sign-in (Firestore rules restrict the shape and
/// only allow writing your own doc).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  String? get uid => _auth.currentUser?.uid;
  bool get isLoggedIn => _auth.currentUser != null;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Starts phone verification for [phoneE164] (e.g. '+919876543210').
  ///
  /// [onCodeSent] fires when the SMS is out — navigate to the OTP screen with
  /// the verificationId. [onAutoVerified] fires on Android instant/auto
  /// verification — the user is already signed in, skip the OTP screen.
  /// [onError] gets a human-readable message.
  Future<void> sendOtp({
    required String phoneE164,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function() onAutoVerified,
    required void Function(String message) onError,
    int? resendToken,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneE164,
      forceResendingToken: resendToken,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        try {
          await _auth.signInWithCredential(credential);
          await _upsertUserDoc();
          onAutoVerified();
        } catch (e) {
          onError(_friendly(e));
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        onError(_friendly(e));
      },
      codeSent: (String verificationId, int? newResendToken) {
        onCodeSent(verificationId, newResendToken);
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  /// Confirms the 6-digit [smsCode] for [verificationId] and signs in.
  /// Returns null on success, or a human-readable error message.
  Future<String?> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      await _auth.signInWithCredential(credential);
      await _upsertUserDoc();
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  Future<void> signOut() => _auth.signOut();

  /// Spark-mode replacement for the `ensureUser` Cloud Function: the client
  /// writes its own profile doc (rules validate shape + ownership).
  Future<void> _upsertUserDoc() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final ref = _db.collection('users').doc(user.uid);
      final snap = await ref.get();
      await ref.set({
        'phone': user.phoneNumber ?? '',
        'displayName':
            snap.exists ? (snap.get('displayName') as String? ?? '') : '',
        'defaultAddress': snap.exists ? snap.data()!['defaultAddress'] : null,
        if (!snap.exists) 'createdAt': FieldValue.serverTimestamp(),
        'lastSeenAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      // Non-fatal: sign-in succeeded; the profile write can retry later.
      debugPrint('[AuthService] user upsert failed: $e');
    }
  }

  static String _friendly(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-phone-number':
          return 'That phone number looks invalid.';
        case 'invalid-verification-code':
          return 'Wrong code — check the SMS and try again.';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a while and try again.';
        case 'quota-exceeded':
          return 'SMS limit reached for today. Please try again tomorrow.';
        case 'network-request-failed':
          return 'No internet connection. Check your network and retry.';
        default:
          return e.message ?? 'Sign-in failed (${e.code}).';
      }
    }
    return 'Sign-in failed. Please try again.';
  }
}
