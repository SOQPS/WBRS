import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/service/meeting_write_service.dart';
import 'package:wbrs/shared/meeting_form.dart';

class EditMeet extends StatelessWidget {
  const EditMeet({super.key, required this.meet, this.service});
  final DocumentSnapshot meet;
  final MeetingWriteService? service;

  @override
  Widget build(BuildContext context) => MeetingForm(
      meetingId: meet.id,
      service: service,
      initialData:
          Map<String, dynamic>.from((meet.data() as Map?) ?? const {}));
}
