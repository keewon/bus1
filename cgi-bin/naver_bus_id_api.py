#!/usr/bin/python

print 'Content-Type: application/json'
print 

import cgi
import cgitb
import urllib, urllib2

cgitb.enable()

form = cgi.FieldStorage()

q = form.getvalue('q', '5')
longitude = form.getvalue('longitude', '')
latitude = form.getvalue('latitude', '')
if longitude == '' or latitude == '':
    searchCoord = ''
else:
    searchCoord = urllib.quote_plus(longitude) + '%3b' + urllib.quote_plus(latitude)

if len(q) > 0:
    url = ("http://map.naver.com/search2/local.nhn?type=BUS_ROUTE&query=" +
        urllib.quote_plus(q) + "&searchCoord=" + searchCoord + "&menu=bus")
    
    req = urllib2.Request(url, headers={ 'User-Agent': 'Mozilla/5.0' })
    print urllib2.urlopen(req).read()

