import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

String? globalAbout,
    globalAge = '',
    globalPol,
    globalCity,
    globalRost,
    globalHobbi;
int globalBalance = 0;
bool globalDeti = false;

//красная,зелёная,белая,оранжевая

String group = '';
int brownGroup = 0, whiteGroup = 0, redGroup = 0, blueGroup = 0;
bool testIsComlpete = false;

int countImages = 0;
List images = [];

int selectedIndex = 1;

//Filter data
String filtrPol = '';
int ageStart = 18, ageEnd = 100;
TextEditingController filterCity = TextEditingController(); // legacy alias
TextEditingController filterCountry = TextEditingController();
TextEditingController filterRegion = TextEditingController();
String meetCity = ''; // legacy alias
String meetCountry = '';
String meetRegion = '';
bool filterByGroup = false;

bool imageStream = true;

FirebaseFirestore firebaseFirestore = FirebaseFirestore.instance;
FirebaseAuth firebaseAuth = FirebaseAuth.instance;
FirebaseMessaging firebaseMessaging = FirebaseMessaging.instance;

List<Map<dynamic, dynamic>> usersFromStream = [];
DateTime lastUpdate = DateTime(2000);

Color grey = const Color(0xD92B201A);
Color darkGrey = const Color(0xE631241D);
Color orange90 = const Color(0xFFE7B092);
Color white70 = const Color(0xFFFFF7EB);
