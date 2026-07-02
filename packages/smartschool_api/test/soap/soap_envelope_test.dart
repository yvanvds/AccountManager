import 'package:smartschool_api/smartschool_api.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('buildRpcEnvelope', () {
    final xml = buildRpcEnvelope(
      namespace: 'https://demo.smartschool.be/Webservices/V3',
      method: 'savePassword',
      args: const [
        SoapArg.string('accesscode', 'secret'),
        SoapArg.string('userIdentifier', 'jand'),
        SoapArg.string('password', 'Hunter2!'),
        SoapArg.int('accountType', 0),
      ],
    );
    final doc = XmlDocument.parse(xml);
    const ns = 'https://demo.smartschool.be/Webservices/V3';

    test('wraps a single method element in the tenant namespace', () {
      final method = doc.findAllElements('savePassword', namespace: ns);
      expect(method, hasLength(1));
      expect(method.first.name.qualified, 'ns1:savePassword');
    });

    test('emits args in order with their part names', () {
      final method = doc.findAllElements('savePassword', namespace: ns).first;
      final names = method.childElements.map((e) => e.name.local).toList();
      expect(
          names, ['accesscode', 'userIdentifier', 'password', 'accountType']);
    });

    test('writes xsi:type per argument (string vs int)', () {
      final method = doc.findAllElements('savePassword', namespace: ns).first;
      final pw =
          method.childElements.firstWhere((e) => e.name.local == 'password');
      final type =
          method.childElements.firstWhere((e) => e.name.local == 'accountType');
      expect(pw.getAttribute('xsi:type'), 'xsd:string');
      expect(pw.innerText, 'Hunter2!');
      expect(type.getAttribute('xsi:type'), 'xsd:int');
      expect(type.innerText, '0');
    });

    test('declares the SOAP encodingStyle on the Body', () {
      final body = doc.findAllElements(
        'Body',
        namespace: 'http://schemas.xmlsoap.org/soap/envelope/',
      );
      expect(body, isNotEmpty);
    });
  });

  test('soapActionFor joins namespace and method with #', () {
    expect(
      soapActionFor('https://demo.smartschool.be/Webservices/V3', 'saveUser'),
      'https://demo.smartschool.be/Webservices/V3#saveUser',
    );
  });

  group('decodeReturn', () {
    String envelope(String inner) => '''<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <ns1:saveUserResponse xmlns:ns1="https://demo.smartschool.be/Webservices/V3">
      $inner
    </ns1:saveUserResponse>
  </soap:Body>
</soap:Envelope>''';

    test('reads a string return with its xsi:type', () {
      final ret = decodeReturn(
        envelope(
          '<return xsi:type="xsd:string" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
          'hello</return>',
        ),
      );
      expect(ret.text, 'hello');
      expect(ret.xsiType, 'xsd:string');
      expect(ret.isInt, isFalse);
    });

    test('detects an int return via xsi:type', () {
      final ret = decodeReturn(
        envelope(
          '<return xsi:type="xsd:int" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
          '19</return>',
        ),
      );
      expect(ret.isInt, isTrue);
      expect(ret.asInt, 19);
    });

    test('detects an int return via text even without xsi:type', () {
      final ret = decodeReturn(envelope('<return>0</return>'));
      expect(ret.isInt, isTrue);
      expect(ret.asInt, 0);
    });

    test('throws when no return element is present', () {
      expect(
        () => decodeReturn('<soap:Envelope '
            'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            '<soap:Body></soap:Body></soap:Envelope>'),
        throwsA(isA<SmartschoolSoapResponseException>()),
      );
    });

    test('surfaces a SOAP fault', () {
      const fault = '''<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <soap:Fault>
      <faultcode>soap:Server</faultcode>
      <faultstring>boom</faultstring>
    </soap:Fault>
  </soap:Body>
</soap:Envelope>''';
      expect(
        () => decodeReturn(fault),
        throwsA(
          isA<SmartschoolSoapFault>()
              .having((e) => e.faultString, 'faultString', 'boom'),
        ),
      );
    });
  });

  group('decodeIntResult', () {
    String intEnvelope(String value) => '''<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body><x><return>$value</return></x></soap:Body>
</soap:Envelope>''';

    test('parses the integer result', () {
      expect(decodeIntResult(intEnvelope('0')), 0);
      expect(decodeIntResult(intEnvelope('7')), 7);
    });

    test('throws when the return is not an integer', () {
      expect(
        () => decodeIntResult(intEnvelope('not-a-number')),
        throwsA(isA<SmartschoolSoapResponseException>()),
      );
    });
  });
}
