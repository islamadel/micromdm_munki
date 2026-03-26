from flask import Flask, request, abort
import base64
import json
import xml.dom.minidom
import re
import os
import operator

app = Flask(__name__)

@app.route('/webhook', methods=['POST'])
def webhook():
	print(request.json)
	for i, dict_item in request.json.items():
		#print ('dict_item = ', dict_item, 'i = ', i)
		if 'raw_payload' in dict_item:
			encoded_string = request.json[i]['raw_payload']
			if encoded_string:
				decoded_string = base64.b64decode(encoded_string)
				#print(base64.b64decode(decoded_string))
				dom = xml.dom.minidom.parseString(decoded_string)
				pretty_xml_as_string = dom.toprettyxml()
				#print(pretty_xml_as_string)
				text = os.linesep.join([s for s in pretty_xml_as_string.splitlines() if re.match(r".*[a-zA-Z0-9]+", s)])
				print(text)
	return ''

if __name__ == '__main__':
	app.run(port=8080)