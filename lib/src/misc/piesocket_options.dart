import 'dart:core';

class PieSocketOptions {
  late String _apiKey;
  late String _clusterId;
  late bool _enableLogs;
  late bool _notifySelf;
  late String _jwt;
  late bool _presence;
  late String _authEndpoint;
  late Map<String, String> _authHeaders;
  late bool _forceAuth;
  late String _userId;
  late String _version;
  late String _webSocketEndpoint;
  late String _clusterDomain;
  late bool _ssl;

  PieSocketOptions() {
    _version = "3";
    _enableLogs = true;
    _notifySelf = true;
    _presence = false;
    _forceAuth = false;
    _clusterId = "";
    _apiKey = "";
    _jwt = "";
    _authEndpoint = "";
    _authHeaders = {};
    _userId = "";
    _webSocketEndpoint = "";
    _clusterDomain = "";
    _ssl = true;
  }

  String getWebSocketEndpoint() {
    return _webSocketEndpoint;
  }

  void setWebSocketEndpoint(String webSocketEndpoint) {
    _webSocketEndpoint = webSocketEndpoint;
  }

  String getClusterDomain() {
    return _clusterDomain;
  }

  void setClusterDomain(String clusterDomain) {
    _clusterDomain = clusterDomain;
  }

  bool getSsl() {
    return _ssl;
  }

  void setSsl(bool ssl) {
    _ssl = ssl;
  }

  String getVersion() {
    return _version;
  }

  void setVersion(String version) {
    _version = version;
  }

  String getApiKey() {
    return _apiKey;
  }

  void setApiKey(String apiKey) {
    _apiKey = apiKey;
  }

  String getClusterId() {
    return _clusterId;
  }

  void setClusterId(String clusterId) {
    _clusterId = clusterId;
  }

  bool getEnableLogs() {
    return _enableLogs;
  }

  void setEnableLogs(bool enableLogs) {
    _enableLogs = enableLogs;
  }

  int getNotifySelf() {
    return _notifySelf ? 1 : 0;
  }

  void setNotifySelf(bool notifySelf) {
    _notifySelf = notifySelf;
  }

  String getJwt() {
    return _jwt;
  }

  void setJwt(String jwt) {
    _jwt = jwt;
  }

  int getPresence() {
    return _presence ? 1 : 0;
  }

  void setPresence(bool presence) {
    _presence = presence;
  }

  String getAuthEndpoint() {
    return _authEndpoint;
  }

  void setAuthEndpoint(String authEndpoint) {
    _authEndpoint = authEndpoint;
  }

  Map<String, String> getAuthHeaders() {
    return _authHeaders;
  }

  void setAuthHeaders(Map<String, String> authHeaders) {
    _authHeaders = authHeaders;
  }

  bool getForceAuth() {
    return _forceAuth;
  }

  void setForceAuth(bool forceAuth) {
    _forceAuth = forceAuth;
  }

  String getUserId() {
    return _userId;
  }

  void setUserId(String userId) {
    _userId = userId;
  }
}
