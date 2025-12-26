#!/usr/bin/env python3
"""
Скрипт для автоматического добавления хостов в Zabbix через API
Версия: 1.0
"""

import requests
import json
import sys
import argparse
from typing import Dict, List, Optional

class ZabbixAPI:
    def __init__(self, url: str, username: str, password: str):
        self.url = url.rstrip('/')
        self.auth_token = None
        self.session = requests.Session()
        self.session.headers.update({'Content-Type': 'application/json-rpc'})
        self.login(username, password)
    
    def _request(self, method: str, params: Dict) -> Dict:
        """Выполнение запроса к Zabbix API"""
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
            "auth": self.auth_token
        }
        
        try:
            response = self.session.post(
                f"{self.url}/api_jsonrpc.php",
                json=payload,
                timeout=30,
                verify=False  # Отключаем проверку SSL для самоподписанных сертификатов
            )
            response.raise_for_status()
            result = response.json()
            
            if 'error' in result:
                raise Exception(f"API Error: {result['error']['data']}")
            
            return result.get('result', {})
            
        except requests.exceptions.RequestException as e:
            raise Exception(f"Request failed: {e}")
    
    def login(self, username: str, password: str) -> None:
        """Аутентификация в Zabbix API"""
        params = {
            "user": username,
            "password": password
        }
        result = self._request("user.login", params)
        self.auth_token = result
    
    def get_template_id(self, template_name: str) -> Optional[str]:
        """Получение ID шаблона по имени"""
        params = {
            "output": ["templateid"],
            "filter": {"host": [template_name]}
        }
        result = self._request("template.get", params)
        return result[0]['templateid'] if result else None
    
    def get_group_id(self, group_name: str) -> Optional[str]:
        """Получение ID группы по имени"""
        params = {
            "output": ["groupid"],
            "filter": {"name": [group_name]}
        }
        result = self._request("hostgroup.get", params)
        return result[0]['groupid'] if result else None
    
    def create_host(self, hostname: str, ip: str, groups: List[str], 
                    templates: List[str], psk_identity: str = None, 
                    psk_key: str = None) -> Dict:
        """Создание нового хоста в Zabbix"""
        
        # Получение ID групп
        group_ids = []
        for group_name in groups:
            group_id = self.get_group_id(group_name)
            if group_id:
                group_ids.append({"groupid": group_id})
            else:
                print(f"Группа '{group_name}' не найдена")
        
        # Получение ID шаблонов
        template_ids = []
        for template_name in templates:
            template_id = self.get_template_id(template_name)
            if template_id:
                template_ids.append({"templateid": template_id})
            else:
                print(f"Шаблон '{template_name}' не найден")
        
        # Подготовка параметров хоста
        host_params = {
            "host": hostname,
            "interfaces": [{
                "type": 1,  # Агент
                "main": 1,
                "useip": 1,
                "ip": ip,
                "dns": "",
                "port": "10050"
            }],
            "groups": group_ids,
            "templates": template_ids,
            "inventory_mode": 0,  # Автоматический инвентарь
            "description": f"Автоматически добавлен через API"
        }
        
        # Добавление PSK если указан
        if psk_identity and psk_key:
            host_params["tls_connect"] = 2  # PSK
            host_params["tls_accept"] = 2   # PSK
            host_params["tls_psk_identity"] = psk_identity
            host_params["tls_psk"] = psk_key
        
        result = self._request("host.create", host_params)
        return result
    
    def bulk_create_hosts(self, hosts_file: str) -> List[Dict]:
        """Массовое создание хостов из CSV файла"""
        import csv
        
        results = []
        
        with open(hosts_file, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            
            for row in reader:
                try:
                    hostname = row['hostname']
                    ip = row['ip']
                    groups = row['groups'].split(',')
                    templates = row['templates'].split(',')
                    
                    psk_identity = row.get('psk_identity')
                    psk_key = row.get('psk_key')
                    
                    print(f"Добавление хоста: {hostname} ({ip})")
                    
                    result = self.create_host(
                        hostname=hostname,
                        ip=ip,
                        groups=groups,
                        templates=templates,
                        psk_identity=psk_identity,
                        psk_key=psk_key
                    )
                    
                    results.append({
                        "hostname": hostname,
                        "status": "success",
                        "hostid": result['hostids'][0] if 'hostids' in result else None
                    })
                    
                    print(f"  ✓ Успешно добавлен (ID: {results[-1]['hostid']})")
                    
                except Exception as e:
                    print(f"  ✗ Ошибка: {e}")
                    results.append({
                        "hostname": row.get('hostname', 'unknown'),
                        "status": "error",
                        "error": str(e)
                    })
        
        return results

def main():
    parser = argparse.ArgumentParser(description='Добавление хостов в Zabbix через API')
    parser.add_argument('--url', required=True, help='URL Zabbix сервера')
    parser.add_argument('--username', default='Admin', help='Имя пользователя Zabbix')
    parser.add_argument('--password', required=True, help='Пароль пользователя Zabbix')
    
    subparsers = parser.add_subparsers(dest='command', help='Команды')
    
    # Команда добавления одного хоста
    single_parser = subparsers.add_parser('add-host', help='Добавить один хост')
    single_parser.add_argument('--hostname', required=True, help='Имя хоста')
    single_parser.add_argument('--ip', required=True, help='IP адрес')
    single_parser.add_argument('--groups', required=True, help='Группы (через запятую)')
    single_parser.add_argument('--templates', required=True, help='Шаблоны (через запятую)')
    single_parser.add_argument('--psk-identity', help='PSK Identity')
    single_parser.add_argument('--psk-key', help='PSK Key')
    
    # Команда массового добавления хостов
    bulk_parser = subparsers.add_parser('bulk-add', help='Массовое добавление хостов')
    bulk_parser.add_argument('--file', required=True, help='CSV файл с хостами')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        sys.exit(1)
    
    try:
        # Подключение к Zabbix API
        print(f"Подключение к Zabbix API: {args.url}")
        zabbix = ZabbixAPI(args.url, args.username, args.password)
        print("✓ Успешная аутентификация")
        
        if args.command == 'add-host':
            # Добавление одного хоста
            groups = args.groups.split(',')
            templates = args.templates.split(',')
            
            result = zabbix.create_host(
                hostname=args.hostname,
                ip=args.ip,
                groups=groups,
                templates=templates,
                psk_identity=args.psk_identity,
                psk_key=args.psk_key
            )
            
            print(f"✓ Хост '{args.hostname}' успешно добавлен")
            print(f"  ID хоста: {result['hostids'][0]}")
            
        elif args.command == 'bulk-add':
            # Массовое добавление хостов
            results = zabbix.bulk_create_hosts(args.file)
            
            # Статистика
            success = len([r for r in results if r['status'] == 'success'])
            errors = len([r for r in results if r['status'] == 'error'])
            
            print(f"\n=== Статистика ===")
            print(f"Успешно: {success}")
            print(f"С ошибками: {errors}")
            
            if errors > 0:
                print(f"\nОшибки:")
                for r in results:
                    if r['status'] == 'error':
                        print(f"  {r['hostname']}: {r['error']}")
        
    except Exception as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
