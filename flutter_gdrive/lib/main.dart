import 'dart:io';
import 'package:firebase_core/firebase_core.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis/drive/v3.dart' as ga;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

Future main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Google Drive',
      theme: ThemeData(primarySwatch: Colors.blue, brightness: Brightness.dark),
      home: MyHomePage(title: 'Google Drive'),
    );
  }
}

class GoogleHttpClient extends IOClient {
  Map<String, String> _headers;

  GoogleHttpClient(this._headers) : super();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      super.send(request..headers.addAll(_headers));

  @override
  Future<http.Response> head(Object url, {Map<String, String> headers}) =>
      super.head(url, headers: headers..addAll(_headers));
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);
  final String title;
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final storage = new FlutterSecureStorage();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn googleSignIn =
      GoogleSignIn(scopes: ['https://www.googleapis.com/auth/drive.appdata']);
  GoogleSignInAccount googleSignInAccount;
  ga.FileList list;
  var signedIn = false;

  Future<void> _loginWithGoogle() async {
    signedIn = await storage.read(key: "signedIn") == "true" ? true : false;
    googleSignIn.onCurrentUserChanged
        .listen((GoogleSignInAccount googleSignInAccount) async {
      if (googleSignInAccount != null) {
        _afterGoogleLogin(googleSignInAccount);
      }
    });
    if (signedIn) {
      try {
        googleSignIn.signInSilently().whenComplete(() => () {});
      } catch (e) {
        storage.write(key: "signedIn", value: "false").then((value) {
          setState(() {
            signedIn = false;
          });
        });
      }
    } else {
      final GoogleSignInAccount googleSignInAccount =
          await googleSignIn.signIn();
      _afterGoogleLogin(googleSignInAccount);
    }
  }

  Future<void> _afterGoogleLogin(GoogleSignInAccount gSA) async {
    googleSignInAccount = gSA;
    final GoogleSignInAuthentication googleSignInAuthentication =
        await googleSignInAccount.authentication;

    final AuthCredential credential = GoogleAuthProvider.getCredential(
      accessToken: googleSignInAuthentication.accessToken,
      idToken: googleSignInAuthentication.idToken,
    );

    final UserCredential authResult =
        await _auth.signInWithCredential(credential);
    final User user = authResult.user;

    assert(!user.isAnonymous);
    assert(await user.getIdToken() != null);

    final User currentUser = await _auth.currentUser;
    assert(user.uid == currentUser.uid);

    print('signInWithGoogle succeeded: $user');

    storage.write(key: "signedIn", value: "true").then((value) {
      setState(() {
        signedIn = true;
      });
    });
  }

  void _logoutFromGoogle() async {
    googleSignIn.signOut().then((value) {
      print("User Sign Out");
      storage.write(key: "signedIn", value: "false").then((value) {
        setState(() {
          signedIn = false;
          list = null;
        });
      });
    });
  }

  _uploadFileToGoogleDrive() async {
    var client = GoogleHttpClient(await googleSignInAccount.authHeaders);
    var drive = ga.DriveApi(client);
    ga.File fileToUpload = ga.File();
    var file = await FilePicker.getFile();
    fileToUpload.parents = ["appDataFolder"];
    fileToUpload.name = path.basename(file.absolute.path);
    var response = await drive.files.create(
      fileToUpload,
      uploadMedia: ga.Media(file.openRead(), file.lengthSync()),
    );
    print(response);
    _listGoogleDriveFiles();
  }

  Future<void> _listGoogleDriveFiles() async {
    var client = GoogleHttpClient(await googleSignInAccount.authHeaders);
    var drive = ga.DriveApi(client);
    drive.files.list(spaces: 'appDataFolder').then((value) {
      setState(() {
        list = value;
      });
      for (var i = 0; i < list.files.length; i++) {
        print("Id: ${list.files[i].id} File Name:${list.files[i].name}");
      }
    });
  }

  Future<void> _deleteGoogleDriveFiles(String gdID) async {
    var client = GoogleHttpClient(await googleSignInAccount.authHeaders);
    var drive = ga.DriveApi(client);
    drive.files.delete(gdID);
    drive.files.list(spaces: 'appDataFolder').then((value) {
      setState(() {
        list = value;
      });
    });
  }

  Future<void> _downloadGoogleDriveFile(String fName, String gdID) async {
    var client = GoogleHttpClient(await googleSignInAccount.authHeaders);
    var drive = ga.DriveApi(client);
    ga.Media file = await drive.files
        .get(gdID, downloadOptions: ga.DownloadOptions.FullMedia);
    print(file.stream);

    final directory = await getExternalStorageDirectory();
    print(directory.path);
    final saveFile = File(
        '${directory.path}/${new DateTime.now().millisecondsSinceEpoch}$fName');
    List<int> dataStore = [];
    file.stream.listen((data) {
      print("DataReceived: ${data.length}");
      dataStore.insertAll(dataStore.length, data);
    }, onDone: () {
      print("Task Done");
      saveFile.writeAsBytes(dataStore);
      print("File saved at ${saveFile.path}");
    }, onError: (error) {
      print("Some Error");
    });
  }

  List<Widget> generateFilesWidget() {
    List<Widget> listItem = List<Widget>();
    if (list != null) {
      for (var i = 0; i < list.files.length; i++) {
        listItem.add(Card(
            child: Row(
          children: <Widget>[
            Container(
              width: MediaQuery.of(context).size.width * 0.09,
              child: getFileIcon(list.files[i].name.split('.').last),
            ),
            Expanded(
              child: Text(list.files[i].name),
            ),
            Container(
              child: IconButton(
                icon: Icon(
                  Icons.download_rounded,
                  color: Colors.greenAccent,
                ),
                onPressed: () {
                  _downloadGoogleDriveFile(
                      list.files[i].name, list.files[i].id);
                },
              ),
            ),
            Container(
              child: IconButton(
                icon: Icon(
                  Icons.delete,
                  color: Colors.greenAccent,
                ),
                onPressed: () {
                  _deleteGoogleDriveFiles(list.files[i].id);
                },
              ),
            )
          ],
        )));
        Divider(
          color: Colors.white,
          height: 2,
        );
      }
    }
    return listItem;
  }

  Widget getFileIcon(name) {
    String extension = '.' + name.split('.').last;

    if ('.jpg, .jpeg, .png'.contains(extension)) {
      return Icon(Icons.image, color: Colors.greenAccent);
    } else if ('.mp3'.contains(extension)) {
      return Icon(Icons.music_note, color: Colors.greenAccent);
    } else if ('.mp4'.contains(extension)) {
      return Icon(Icons.video_label, color: Colors.greenAccent);
    } else if ('.pdf'.contains(extension)) {
      return Icon(Icons.picture_as_pdf, color: Colors.greenAccent);
    } else if ('.docx'.contains(extension)) {
      return Icon(Icons.article, color: Colors.greenAccent);
    }
    return Icon(Icons.archive, color: Colors.greenAccent);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    int _currrentIndex = 0;

    if (signedIn) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
        ),
        drawer: new Drawer(
          child: new ListView(
            children: <Widget>[
              new UserAccountsDrawerHeader(
                accountName: Text(user.displayName),
                accountEmail: Text(user.email),
                currentAccountPicture: new GestureDetector(
                    child: new CircleAvatar(
                  backgroundImage: new NetworkImage(user.photoURL),
                )),
                decoration: new BoxDecoration(),
              ),
              new ListTile(
                title: new Text("My Files"),
                trailing: new Icon(Icons.file_copy),
                onTap: _listGoogleDriveFiles,
              ),
              new ListTile(
                  title: new Text("Shared Files"),
                  trailing: new Icon(Icons.share)),
              new Divider(),
              new ListTile(
                title: new Text("Logout"),
                trailing: new Icon(Icons.logout),
                onTap: _logoutFromGoogle,
              ),
            ],
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              (signedIn
                  ? FlatButton(
                      child: Text('List Google Drive Files'),
                      onPressed: _listGoogleDriveFiles,
                      color: Colors.greenAccent,
                    )
                  : Container()),
              (signedIn
                  ? Expanded(
                      flex: 10,
                      child: ListView(
                        children: generateFilesWidget(),
                      ),
                    )
                  : Container()),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: FloatingActionButton(
          onPressed: _uploadFileToGoogleDrive,
          tooltip: 'Increment',
          child: Icon(Icons.add),
          elevation: 2.0,
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currrentIndex,
          type: BottomNavigationBarType.fixed,
          showSelectedLabels: true,
          showUnselectedLabels: false,
          selectedItemColor: Colors.blue.shade700,
          items: [
            BottomNavigationBarItem(
                icon: _currrentIndex == 0
                    ? Icon(
                        Icons.home,
                        size: 25,
                      )
                    : Icon(Icons.home_outlined, size: 25),
                title: Text("Home")),
            BottomNavigationBarItem(
                icon: _currrentIndex == 1
                    ? Icon(
                        Icons.star,
                        size: 25,
                      )
                    : Icon(Icons.star_border_outlined, size: 25),
                title: Text("Starred")),
            BottomNavigationBarItem(
                icon: _currrentIndex == 2
                    ? Icon(
                        Icons.supervised_user_circle,
                        size: 25,
                      )
                    : Icon(Icons.supervised_user_circle, size: 25),
                title: Text("Shared")),
            BottomNavigationBarItem(
                icon: _currrentIndex == 3
                    ? Icon(
                        Icons.folder,
                        size: 25,
                      )
                    : Icon(Icons.folder_open, size: 25),
                title: Text("Files")),
          ],
        ),
      );
    } else {
      return Scaffold(
          body: Center(
        child: Column(
          children: [
            Spacer(),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: 20),
                width: 175,
                child: Text(
                  'Welcome Back To FileHub',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Spacer(),
            Container(
              padding: EdgeInsets.all(4),
              child: OutlineButton.icon(
                label: Text(
                  'Sign In With Google',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                ),
                shape: StadiumBorder(),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                highlightedBorderColor: Colors.black,
                borderSide: BorderSide(color: Colors.black),
                textColor: Colors.white,
                icon:
                    FaIcon(FontAwesomeIcons.google, color: Colors.greenAccent),
                onPressed: _loginWithGoogle,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Login to continue',
              style: TextStyle(fontSize: 16),
            ),
            Spacer(),
          ],
        ),
      ));
    }
  }
}
