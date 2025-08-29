#!/usr/bin/with-contenv bashio

if [ -z ${STANDALONE+x} ]; then
  export FcaAssistant_fca__user=$(bashio::config 'Username')
  export FcaAssistant_fca__password=$(bashio::config 'Password')
  export FcaAssistant_fca__pin=$(bashio::config 'Pin')
  export FcaAssistant_fca__brand=$(bashio::config 'Brand')
  export FcaAssistant_fca__region=$(bashio::config 'Region')

  export FcaAssistant_app__unit=$(bashio::config 'DistanceUnit')
  export FcaAssistant_app__startDelaySeconds=$(bashio::config 'StartDelaySeconds')
  export FcaAssistant_app__refreshInterval=$(bashio::config 'RefreshInterval')
  export FcaAssistant_app__autoRefreshLocation=$(bashio::config 'AutoRefreshLocation')
  export FcaAssistant_app__autoRefreshBattery=$(bashio::config 'AutoRefreshBattery')
  export FcaAssistant_app__enableDangerousCommands=$(bashio::config 'EnableDangerousCommands')
  export FcaAssistant_app__carUnknownLocation=$(bashio::config 'CarUnknownLocation')

  export FcaAssistant_serilog__MinimumLevel=$(bashio::config 'Loglevel')

  export FcaAssistant_ha__api__token=$SUPERVISOR_TOKEN
  export FcaAssistant_ha__mqtt_server=$(bashio::config 'OverrideMqttServer')
  export FcaAssistant_ha__mqtt_port=$(bashio::config 'OverrideMqttPort')
  export FcaAssistant_ha__mqtt_user=$(bashio::config 'OverrideMqttUser')
  export FcaAssistant_ha__mqtt_password=$(bashio::config 'OverrideMqttPw')
  
  test "$FcaAssistant_ha__mqtt_server" = "null" && export FcaAssistant_ha__mqtt_server=$(bashio::services "mqtt" "host")
  test "$FcaAssistant_ha__mqtt_port" = "null" && export FcaAssistant_ha__mqtt_port=$(bashio::services "mqtt" "port")
  test "$FcaAssistant_ha__mqtt_user" = "null" && export FcaAssistant_ha__mqtt_user=$(bashio::services "mqtt" "username")
  test "$FcaAssistant_ha__mqtt_password" = "null" && export FcaAssistant_ha__mqtt_password=$(bashio::services "mqtt" "password")
else
  echo "RUNNING IN STANDALONE MODE"
fi

cd /app
./FcaAssistant