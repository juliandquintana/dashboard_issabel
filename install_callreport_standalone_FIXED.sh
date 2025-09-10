#!/bin/bash

# Call Reports Dashboard - Instalación Independiente
# No interfiere con Issabel PBX - Dashboard Standalone
# Versión: 2.0.0 Independiente

set -e

# Configuration
DASHBOARD_NAME="callreports"
DASHBOARD_DIR="/var/www/html/$DASHBOARD_NAME"
BACKUP_DIR="/tmp/callreports_standalone_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/callreports_standalone.log"
DB_USER_NAME="callreports_user"
VHOST_PORT="8081"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
    log "[INFO] $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "[WARNING] $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "[ERROR] $1"
}

print_success() {
    echo -e "${PURPLE}[SUCCESS]${NC} $1"
    log "[SUCCESS] $1"
}

print_header() {
    echo -e "${BLUE}
╔══════════════════════════════════════════════════════════════════╗
║              Call Reports Dashboard - Independiente             ║
║                         Versión 2.0.0                           ║
║                 Sin dependencias de Issabel PBX                 ║
╚══════════════════════════════════════════════════════════════════╝
${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    print_status "Verificando requisitos del sistema..."
    
    # Check if Apache/Nginx is running
    if ! systemctl is-active --quiet httpd && ! systemctl is-active --quiet apache2 && ! systemctl is-active --quiet nginx; then
        print_error "No hay servidor web ejecutándose (Apache/Nginx)"
        exit 1
    fi
    
    # Check if MySQL/MariaDB is running
    if ! systemctl is-active --quiet mysqld && ! systemctl is-active --quiet mariadb; then
        print_error "MySQL/MariaDB no está ejecutándose"
        exit 1
    fi
    
    # Check PHP installation
    if ! command -v php &> /dev/null; then
        print_error "PHP no está instalado"
        exit 1
    fi
    
    # Check PHP extensions
    php_extensions=("mysqli" "json" "mbstring")
    for ext in "${php_extensions[@]}"; do
        if ! php -m | grep -q "^$ext$"; then
            print_error "Extensión PHP requerida no encontrada: $ext"
            exit 1
        fi
    done
    
    # Check if /var/www/html exists and is writable
    if [ ! -d "/var/www/html" ]; then
        print_error "Directorio /var/www/html no existe"
        exit 1
    fi
    
    if [ ! -w "/var/www/html" ]; then
        print_error "No hay permisos de escritura en /var/www/html"
        exit 1
    fi
    
    print_status "Verificación de requisitos completada"
}

# Create dashboard structure
create_dashboard_structure() {
    print_status "Creando estructura del dashboard independiente..."
    
    # Backup existing installation if exists
    if [ -d "$DASHBOARD_DIR" ]; then
        print_status "Respaldando instalación existente..."
        mkdir -p "$BACKUP_DIR"
        cp -r "$DASHBOARD_DIR" "$BACKUP_DIR/"
        print_status "Respaldo creado en: $BACKUP_DIR"
        rm -rf "$DASHBOARD_DIR"
    fi
    
    # Create main structure
    mkdir -p "$DASHBOARD_DIR"/{api,assets/{css,js,images,lib},config,includes,data,logs,reports}
    
    # Create additional directories
    mkdir -p "$DASHBOARD_DIR/assets/lib"/{chartjs,jquery}
    
    # Set basic permissions
    chown -R apache:apache "$DASHBOARD_DIR" 2>/dev/null || chown -R www-data:www-data "$DASHBOARD_DIR"
    chmod -R 755 "$DASHBOARD_DIR"
    chmod -R 777 "$DASHBOARD_DIR"/{data,logs,reports}
    
    print_status "Estructura de directorios creada en: $DASHBOARD_DIR"
}
# Get database configuration
get_database_config() {
    print_status "Configurando acceso a base de datos..."
    
    # Try to read from Issabel config files (only for CDR access)
    DB_HOST=""
    DB_ROOT_USER=""
    DB_ROOT_PASS=""
    CDR_DB=""
    
    # Method 1: Try /etc/amportal.conf
    if [ -f "/etc/amportal.conf" ]; then
        print_status "Leyendo configuración de BD desde /etc/amportal.conf..."
        DB_HOST=$(grep "^AMPDBHOST=" /etc/amportal.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
        DB_ROOT_USER=$(grep "^AMPDBUSER=" /etc/amportal.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
        DB_ROOT_PASS=$(grep "^AMPDBPASS=" /etc/amportal.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
        CDR_DB=$(grep "^CDRDBNAME=" /etc/amportal.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
    fi
    
    # Method 2: Try /etc/issabel.conf
    if [ -z "$DB_HOST" ] && [ -f "/etc/issabel.conf" ]; then
        print_status "Leyendo configuración de BD desde /etc/issabel.conf..."
        DB_HOST=$(grep "^MYSQL_HOST=" /etc/issabel.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
        DB_ROOT_USER="root"
        DB_ROOT_PASS=$(grep "^MYSQL_PASS=" /etc/issabel.conf | cut -d'=' -f2 2>/dev/null | tr -d '"' | xargs)
        CDR_DB="asteriskcdrdb"
    fi
    
    # Set defaults if needed
    if [ -z "$DB_HOST" ]; then
        print_warning "Configuración automática no encontrada, usando valores por defecto..."
        DB_HOST="localhost"
        DB_ROOT_USER="root"
        CDR_DB="asteriskcdrdb"
    fi
    
    # Ask for password if not found
    if [ -z "$DB_ROOT_PASS" ]; then
        echo -e "${YELLOW}[INPUT]${NC} Ingrese la contraseña de MySQL para el usuario '$DB_ROOT_USER':"
        read -s DB_ROOT_PASS
        echo
    fi
    
    # Test connection
    print_status "Probando conexión a MySQL..."
    if ! mysql -h"$DB_HOST" -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "SELECT 1;" &>/dev/null; then
        print_error "No se puede conectar a MySQL. Verifique las credenciales."
        exit 1
    fi
    
    print_success "Conexión a MySQL exitosa"
    
    # Store config for other functions
    export DB_HOST DB_ROOT_USER DB_ROOT_PASS CDR_DB DB_USER_NAME
}

# Create dedicated database user
create_database_user() {
    print_status "Creando usuario dedicado para el dashboard..."
    
    # Generate secure password
    DB_USER_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Create database user with limited privileges (only SELECT on CDR)
    mysql -h"$DB_HOST" -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" << SQLEOF
-- Create user if not exists
CREATE USER IF NOT EXISTS '${DB_USER_NAME}'@'localhost' IDENTIFIED BY '${DB_USER_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER_NAME}'@'%' IDENTIFIED BY '${DB_USER_PASS}';

-- Grant only SELECT privileges on CDR database
GRANT SELECT ON ${CDR_DB}.* TO '${DB_USER_NAME}'@'localhost';
GRANT SELECT ON ${CDR_DB}.* TO '${DB_USER_NAME}'@'%';

-- Additional privileges for queue_log and other reporting tables
GRANT SELECT ON ${CDR_DB}.queue_log TO '${DB_USER_NAME}'@'localhost' WITH GRANT OPTION;
GRANT SELECT ON ${CDR_DB}.queue_log TO '${DB_USER_NAME}'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQLEOF

    if [ $? -eq 0 ]; then
        print_success "Usuario de base de datos creado: $DB_USER_NAME"
        export DB_USER_PASS
    else
        print_error "Falló la creación del usuario de base de datos"
        exit 1
    fi
}

# Create database configuration file
create_database_config() {
    print_status "Creando archivo de configuración de base de datos..."
    
    cat > "$DASHBOARD_DIR/config/database.php" << EOF
<?php
/**
 * Call Reports Dashboard - Database Configuration
 * Standalone version - No Issabel PBX dependencies
 */

class DatabaseConfig {
    // Database connection parameters
    const DB_HOST = '${DB_HOST}';
    const DB_USER = '${DB_USER_NAME}';
    const DB_PASS = '${DB_USER_PASS}';
    const CDR_DATABASE = '${CDR_DB}';
    const DB_CHARSET = 'utf8mb4';
    
    // Dashboard settings
    const DASHBOARD_NAME = 'Call Reports Dashboard';
    const DASHBOARD_VERSION = '2.0.0';
    const TIMEZONE = 'America/Bogota';
    
    // Security settings
    const ENABLE_AUTH = false; // Set to true to enable authentication
    const SESSION_TIMEOUT = 3600; // 1 hour
    const MAX_RECORDS = 10000; // Maximum records per query
    
    // Cache settings
    const CACHE_ENABLED = true;
    const CACHE_DURATION = 300; // 5 minutes
    
    public static function getConnectionString() {
        return sprintf(
            "mysql:host=%s;dbname=%s;charset=%s",
            self::DB_HOST,
            self::CDR_DATABASE,
            self::DB_CHARSET
        );
    }
}

// Set timezone
date_default_timezone_set(DatabaseConfig::TIMEZONE);

// Error reporting for development (disable in production)
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', dirname(__DIR__) . '/logs/error.log');
?>
EOF
    
    print_success "Configuración de base de datos creada"
}

# Create main settings file
create_settings_config() {
    print_status "Creando archivo de configuración general..."
    
    cat > "$DASHBOARD_DIR/config/settings.php" << 'EOF'
<?php
/**
 * Call Reports Dashboard - General Settings
 */

class Settings {
    // Display settings
    const DEFAULT_DATE_RANGE = 30; // days
    const RECORDS_PER_PAGE = 100;
    const CHARTS_REFRESH_INTERVAL = 30000; // milliseconds
    const REALTIME_REFRESH_INTERVAL = 5000; // milliseconds
    
    // Export settings
    const EXPORT_FORMATS = ['csv', 'json'];
    const CSV_DELIMITER = ',';
    const CSV_ENCLOSURE = '"';
    
    // Chart colors
    const CHART_COLORS = [
        '#667eea', '#764ba2', '#f093fb', '#f5576c',
        '#4facfe', '#00f2fe', '#43e97b', '#38f9d7',
        '#ffecd2', '#fcb69f', '#a8edea', '#fed6e3'
    ];
    
    // Status mappings
    const CALL_DISPOSITIONS = [
        'ANSWERED' => ['label' => 'Contestada', 'color' => '#28a745'],
        'NO ANSWER' => ['label' => 'Sin Respuesta', 'color' => '#ffc107'],
        'BUSY' => ['label' => 'Ocupado', 'color' => '#fd7e14'],
        'FAILED' => ['label' => 'Fallida', 'color' => '#dc3545'],
        'CONGESTION' => ['label' => 'Congestión', 'color' => '#6f42c1']
    ];
    
    public static function getDateRange($days = null) {
        $days = $days ?: self::DEFAULT_DATE_RANGE;
        $end = new DateTime();
        $start = new DateTime();
        $start->sub(new DateInterval('P' . $days . 'D'));
        
        return [
            'start' => $start->format('Y-m-d 00:00:00'),
            'end' => $end->format('Y-m-d 23:59:59')
        ];
    }
    
    public static function formatDuration($seconds) {
        if ($seconds === null || $seconds === '') return '00:00:00';
        
        $hours = floor($seconds / 3600);
        $minutes = floor(($seconds % 3600) / 60);
        $seconds = $seconds % 60;
        
        return sprintf('%02d:%02d:%02d', $hours, $minutes, $seconds);
    }
    
    public static function sanitizeInput($input) {
        return htmlspecialchars(trim($input), ENT_QUOTES, 'UTF-8');
    }
}
?>
EOF
    
    print_success "Configuración general creada"
}
# Create Database class
create_database_class() {
    print_status "Creando clase Database..."
    
    cat > "$DASHBOARD_DIR/includes/Database.class.php" << 'EOF'
<?php
/**
 * Database Class - Standalone MySQL connection
 * No dependencies on Issabel PBX
 */

require_once dirname(__DIR__) . '/config/database.php';

class Database {
    private $pdo;
    private $lastError;
    private static $instance = null;
    
    private function __construct() {
        $this->connect();
    }
    
    public static function getInstance() {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }
    
    private function connect() {
        try {
            $dsn = DatabaseConfig::getConnectionString();
            $this->pdo = new PDO($dsn, DatabaseConfig::DB_USER, DatabaseConfig::DB_PASS, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
                PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES " . DatabaseConfig::DB_CHARSET
            ]);
        } catch (PDOException $e) {
            $this->lastError = $e->getMessage();
            error_log("Database connection failed: " . $e->getMessage());
            throw new Exception("Database connection failed");
        }
    }
    
    public function query($sql, $params = []) {
        try {
            $stmt = $this->pdo->prepare($sql);
            $stmt->execute($params);
            return $stmt;
        } catch (PDOException $e) {
            $this->lastError = $e->getMessage();
            error_log("Query failed: " . $e->getMessage() . " SQL: " . $sql);
            return false;
        }
    }
    
    public function fetchAll($sql, $params = []) {
        $stmt = $this->query($sql, $params);
        return $stmt ? $stmt->fetchAll() : [];
    }
    
    public function fetchRow($sql, $params = []) {
        $stmt = $this->query($sql, $params);
        return $stmt ? $stmt->fetch() : null;
    }
    
    public function fetchColumn($sql, $params = []) {
        $stmt = $this->query($sql, $params);
        return $stmt ? $stmt->fetchColumn() : null;
    }
    
    public function getLastError() {
        return $this->lastError;
    }
    
    public function isConnected() {
        try {
            return $this->pdo && $this->pdo->getAttribute(PDO::ATTR_CONNECTION_STATUS);
        } catch (Exception $e) {
            return false;
        }
    }
    
    // Prevent cloning
    private function __clone() {}
    
    // Prevent unserialization
    private function __wakeup() {}
}
?>
EOF
    
    print_success "Clase Database creada"
}

# Create CallReports main class
create_callreports_class() {
    print_status "Creando clase CallReports..."
    
    cat > "$DASHBOARD_DIR/includes/CallReports.class.php" << 'EOF'
<?php
/**
 * CallReports Class - Main business logic
 * Standalone version for Call Reports Dashboard
 */

require_once __DIR__ . '/Database.class.php';
require_once dirname(__DIR__) . '/config/settings.php';

class CallReports {
    private $db;
    private $cache;
    
    public function __construct() {
        $this->db = Database::getInstance();
        $this->cache = [];
    }
    
    /**
     * Get call summary statistics
     */
    public function getCallSummary($dateStart, $dateEnd, $extension = '') {
        $cacheKey = 'summary_' . md5($dateStart . $dateEnd . $extension);
        
        if (isset($this->cache[$cacheKey])) {
            return $this->cache[$cacheKey];
        }
        
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $params[] = $extension;
            $params[] = $extension;
        }
        
        $sql = "SELECT 
                    COUNT(*) as total_calls,
                    COUNT(CASE WHEN disposition = 'ANSWERED' THEN 1 END) as answered_calls,
                    COUNT(CASE WHEN disposition = 'NO ANSWER' THEN 1 END) as no_answer_calls,
                    COUNT(CASE WHEN disposition = 'BUSY' THEN 1 END) as busy_calls,
                    COUNT(CASE WHEN disposition = 'FAILED' THEN 1 END) as failed_calls,
                    AVG(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as avg_duration,
                    SUM(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as total_duration,
                    MAX(billsec) as max_duration,
                    MIN(CASE WHEN disposition = 'ANSWERED' AND billsec > 0 THEN billsec END) as min_duration
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere";
        
        $result = $this->db->fetchRow($sql, $params);
        
        if ($result) {
            $result['answer_rate'] = $result['total_calls'] > 0 ? 
                round(($result['answered_calls'] / $result['total_calls']) * 100, 2) : 0;
            $result['avg_duration_formatted'] = Settings::formatDuration($result['avg_duration']);
            $result['total_duration_formatted'] = Settings::formatDuration($result['total_duration']);
            $result['max_duration_formatted'] = Settings::formatDuration($result['max_duration']);
            $result['min_duration_formatted'] = Settings::formatDuration($result['min_duration']);
        }
        
        $this->cache[$cacheKey] = $result;
        return $result;
    }
    
    /**
     * Get hourly call distribution
     */
    public function getHourlyDistribution($dateStart, $dateEnd, $extension = '') {
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $params[] = $extension;
            $params[] = $extension;
        }
        
        $sql = "SELECT 
                    HOUR(calldate) as hour,
                    COUNT(*) as call_count,
                    COUNT(CASE WHEN disposition = 'ANSWERED' THEN 1 END) as answered_count,
                    AVG(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as avg_duration
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere
                GROUP BY HOUR(calldate)
                ORDER BY hour";
        
        $result = $this->db->fetchAll($sql, $params);
        
        // Fill missing hours with zeros
        $hourlyData = array_fill(0, 24, [
            'hour' => 0, 'call_count' => 0, 
            'answered_count' => 0, 'avg_duration' => 0
        ]);
        
        foreach ($result as $row) {
            $hourlyData[$row['hour']] = $row;
        }
        
        return array_values($hourlyData);
    }
    
    /**
     * Get daily trends
     */
    public function getDailyTrends($dateStart, $dateEnd, $extension = '') {
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $params[] = $extension;
            $params[] = $extension;
        }
        
        $sql = "SELECT 
                    DATE(calldate) as call_date,
                    COUNT(*) as call_count,
                    COUNT(CASE WHEN disposition = 'ANSWERED' THEN 1 END) as answered_count,
                    SUM(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as total_duration,
                    AVG(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as avg_duration
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere
                GROUP BY DATE(calldate)
                ORDER BY call_date";
        
        $result = $this->db->fetchAll($sql, $params);
        
        foreach ($result as &$row) {
            $row['answer_rate'] = $row['call_count'] > 0 ? 
                round(($row['answered_count'] / $row['call_count']) * 100, 2) : 0;
            $row['avg_duration_formatted'] = Settings::formatDuration($row['avg_duration']);
            $row['total_duration_formatted'] = Settings::formatDuration($row['total_duration']);
        }
        
        return $result;
    }
    
    /**
     * Get extension statistics
     */
    public function getExtensionStats($dateStart, $dateEnd, $extension = '') {
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $params[] = $extension;
            $params[] = $extension;
        }
        
        $sql = "SELECT 
                    CASE 
                        WHEN src REGEXP '^[0-9]{3,4}$' THEN src 
                        WHEN dst REGEXP '^[0-9]{3,4}$' THEN dst 
                        ELSE 'External' 
                    END as extension,
                    COUNT(*) as call_count,
                    COUNT(CASE WHEN disposition = 'ANSWERED' THEN 1 END) as answered_count,
                    SUM(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as total_duration,
                    AVG(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as avg_duration
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere
                GROUP BY extension
                HAVING call_count > 0
                ORDER BY call_count DESC
                LIMIT 20";
        
        $result = $this->db->fetchAll($sql, $params);
        
        foreach ($result as &$row) {
            $row['answer_rate'] = $row['call_count'] > 0 ? 
                round(($row['answered_count'] / $row['call_count']) * 100, 2) : 0;
            $row['avg_duration_formatted'] = Settings::formatDuration($row['avg_duration']);
            $row['total_duration_formatted'] = Settings::formatDuration($row['total_duration']);
        }
        
        return $result;
    }
    
    /**
     * Get top destinations
     */
    public function getTopDestinations($dateStart, $dateEnd, $extension = '') {
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND src = ?';
            $params[] = $extension;
        }
        
        $sql = "SELECT 
                    dst as destination,
                    COUNT(*) as call_count,
                    COUNT(CASE WHEN disposition = 'ANSWERED' THEN 1 END) as answered_count,
                    SUM(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as total_duration,
                    AVG(CASE WHEN disposition = 'ANSWERED' THEN billsec END) as avg_duration
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere
                GROUP BY dst
                HAVING call_count > 0
                ORDER BY call_count DESC
                LIMIT 10";
        
        $result = $this->db->fetchAll($sql, $params);
        
        foreach ($result as &$row) {
            $row['answer_rate'] = $row['call_count'] > 0 ? 
                round(($row['answered_count'] / $row['call_count']) * 100, 2) : 0;
            $row['total_duration_formatted'] = Settings::formatDuration($row['total_duration']);
            $row['avg_duration_formatted'] = Settings::formatDuration($row['avg_duration']);
        }
        
        return $result;
    }
    
    /**
     * Get call details with pagination
     */
    public function getCallDetails($dateStart, $dateEnd, $extension = '', $limit = 100, $offset = 0) {
        $params = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $params[] = $extension;
            $params[] = $extension;
        }
        
        // Add limit and offset to params
        $params[] = (int)$limit;
        $params[] = (int)$offset;
        
        $sql = "SELECT 
                    calldate,
                    clid,
                    src,
                    dst,
                    dcontext,
                    channel,
                    dstchannel,
                    duration,
                    billsec,
                    disposition,
                    uniqueid
                FROM cdr 
                WHERE calldate BETWEEN ? AND ? $extensionWhere
                ORDER BY calldate DESC
                LIMIT ? OFFSET ?";
        
        $result = $this->db->fetchAll($sql, $params);
        
        foreach ($result as &$row) {
            $row['duration_formatted'] = Settings::formatDuration($row['duration']);
            $row['billsec_formatted'] = Settings::formatDuration($row['billsec']);
            $row['calldate_formatted'] = date('d/m/Y H:i:s', strtotime($row['calldate']));
        }
        
        return $result;
    }
    
    /**
     * Get available extensions
     */
    public function getExtensions() {
        // This is a simple approach - in a real scenario you might query sip/pjsip tables
        $sql = "SELECT DISTINCT src as extension 
                FROM cdr 
                WHERE src REGEXP '^[0-9]{3,4}$' 
                ORDER BY CAST(src AS UNSIGNED)
                LIMIT 100";
        
        $result = $this->db->fetchAll($sql);
        
        $extensions = ['' => 'All Extensions'];
        foreach ($result as $row) {
            $extensions[$row['extension']] = $row['extension'];
        }
        
        return $extensions;
    }
    
    /**
     * Test database connection
     */
    public function testConnection() {
        return $this->db->isConnected();
    }
}
?>
EOF
    
    print_success "Clase CallReports creada"
}
# Create API for dashboard data
create_dashboard_data_api() {
    print_status "Creando API dashboard-data.php..."
    
    cat > "$DASHBOARD_DIR/api/dashboard-data.php" << 'EOF'
<?php
/**
 * Dashboard Data API
 * Returns comprehensive dashboard statistics
 */

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

// Handle preflight OPTIONS request
if ($_SERVER['REQUEST_METHOD'] == 'OPTIONS') {
    exit(0);
}

require_once '../includes/CallReports.class.php';

try {
    $callReports = new CallReports();
    
    // Get parameters
    $dateStart = $_GET['date_start'] ?? date('Y-m-d 00:00:00', strtotime('-30 days'));
    $dateEnd = $_GET['date_end'] ?? date('Y-m-d 23:59:59');
    $extension = $_GET['extension'] ?? '';
    
    // Validate date format
    if (!DateTime::createFromFormat('Y-m-d H:i:s', $dateStart) || 
        !DateTime::createFromFormat('Y-m-d H:i:s', $dateEnd)) {
        throw new Exception('Invalid date format. Use Y-m-d H:i:s');
    }
    
    // Validate date range (not more than 1 year)
    $start = new DateTime($dateStart);
    $end = new DateTime($dateEnd);
    $interval = $start->diff($end);
    if ($interval->days > 365) {
        throw new Exception('Date range cannot exceed 365 days');
    }
    
    // Sanitize extension
    $extension = Settings::sanitizeInput($extension);
    
    // Get all dashboard data
    $data = [
        'status' => 'success',
        'timestamp' => time(),
        'date_range' => [
            'start' => $dateStart,
            'end' => $dateEnd,
            'extension' => $extension
        ],
        'call_summary' => $callReports->getCallSummary($dateStart, $dateEnd, $extension),
        'hourly_distribution' => $callReports->getHourlyDistribution($dateStart, $dateEnd, $extension),
        'daily_trends' => $callReports->getDailyTrends($dateStart, $dateEnd, $extension),
        'extension_stats' => $callReports->getExtensionStats($dateStart, $dateEnd, $extension),
        'top_destinations' => $callReports->getTopDestinations($dateStart, $dateEnd, $extension)
    ];
    
    echo json_encode($data, JSON_PRETTY_PRINT);

} catch (Exception $e) {
    http_response_code(400);
    echo json_encode([
        'status' => 'error',
        'message' => $e->getMessage(),
        'timestamp' => time()
    ]);
}
?>
EOF

    print_success "API dashboard-data.php creada"
}

# Create API for call details
create_call_details_api() {
    print_status "Creando API call-details.php..."
    
    cat > "$DASHBOARD_DIR/api/call-details.php" << 'EOF'
<?php
/**
 * Call Details API
 * Returns detailed call records with pagination
 */

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] == 'OPTIONS') {
    exit(0);
}

require_once '../includes/CallReports.class.php';

try {
    $callReports = new CallReports();
    
    // Get parameters
    $dateStart = $_GET['date_start'] ?? date('Y-m-d 00:00:00', strtotime('-7 days'));
    $dateEnd = $_GET['date_end'] ?? date('Y-m-d 23:59:59');
    $extension = $_GET['extension'] ?? '';
    $limit = min(max((int)($_GET['limit'] ?? 100), 1), 1000); // Between 1 and 1000
    $offset = max((int)($_GET['offset'] ?? 0), 0);
    
    // Validate dates
    if (!DateTime::createFromFormat('Y-m-d H:i:s', $dateStart) || 
        !DateTime::createFromFormat('Y-m-d H:i:s', $dateEnd)) {
        throw new Exception('Invalid date format. Use Y-m-d H:i:s');
    }
    
    // Sanitize extension
    $extension = Settings::sanitizeInput($extension);
    
    // Get call details
    $callDetails = $callReports->getCallDetails($dateStart, $dateEnd, $extension, $limit, $offset);
    
    // Calculate total count for pagination (optional, expensive query)
    $totalCount = null;
    if (isset($_GET['include_total']) && $_GET['include_total'] == '1') {
        // This is an expensive operation, only do it when explicitly requested
        $db = Database::getInstance();
        $countParams = [$dateStart, $dateEnd];
        $extensionWhere = '';
        
        if (!empty($extension)) {
            $extensionWhere = ' AND (src = ? OR dst = ?)';
            $countParams[] = $extension;
            $countParams[] = $extension;
        }
        
        $countSql = "SELECT COUNT(*) FROM cdr WHERE calldate BETWEEN ? AND ? $extensionWhere";
        $totalCount = $db->fetchColumn($countSql, $countParams);
    }
    
    $response = [
        'status' => 'success',
        'timestamp' => time(),
        'pagination' => [
            'limit' => $limit,
            'offset' => $offset,
            'returned_records' => count($callDetails),
            'total_count' => $totalCount
        ],
        'filters' => [
            'date_start' => $dateStart,
            'date_end' => $dateEnd,
            'extension' => $extension
        ],
        'data' => $callDetails
    ];
    
    echo json_encode($response, JSON_PRETTY_PRINT);

} catch (Exception $e) {
    http_response_code(400);
    echo json_encode([
        'status' => 'error',
        'message' => $e->getMessage(),
        'timestamp' => time()
    ]);
}
?>
EOF

    print_success "API call-details.php creada"
}

# Create API for real-time data
create_realtime_api() {
    print_status "Creando API real-time.php..."
    
    cat > "$DASHBOARD_DIR/api/real-time.php" << 'EOF'
<?php
/**
 * Real-time Data API
 * Returns current system status and active calls
 */

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] == 'OPTIONS') {
    exit(0);
}

require_once '../includes/CallReports.class.php';

try {
    $callReports = new CallReports();
    $db = Database::getInstance();
    
    // Get current active calls (calls in progress)
    // Note: This is a simplified approach. In production, you'd query active channels
    $activeCalls = [
        'total_active' => 0,
        'inbound' => 0,
        'outbound' => 0,
        'internal' => 0
    ];
    
    // Get recent activity (last hour)
    $lastHour = date('Y-m-d H:i:s', strtotime('-1 hour'));
    $now = date('Y-m-d H:i:s');
    
    $recentStats = $callReports->getCallSummary($lastHour, $now);
    
    // Get system status
    $systemStatus = [
        'database_status' => $db->isConnected() ? 'connected' : 'disconnected',
        'last_call_time' => null,
        'calls_last_hour' => $recentStats['total_calls'] ?? 0,
        'answered_last_hour' => $recentStats['answered_calls'] ?? 0
    ];
    
    // Get timestamp of last call
    $lastCallSql = "SELECT MAX(calldate) as last_call FROM cdr";
    $lastCall = $db->fetchRow($lastCallSql);
    if ($lastCall && $lastCall['last_call']) {
        $systemStatus['last_call_time'] = $lastCall['last_call'];
        $systemStatus['last_call_ago'] = time() - strtotime($lastCall['last_call']);
    }
    
    // Get queue statistics (if queue_log table exists)
    $queueStats = [];
    try {
        $queueSql = "SELECT 
                        queuename,
                        COUNT(CASE WHEN event = 'COMPLETECALLER' THEN 1 END) as completed_calls,
                        COUNT(CASE WHEN event = 'ABANDON' THEN 1 END) as abandoned_calls,
                        AVG(CASE WHEN event = 'COMPLETECALLER' THEN CAST(data1 AS UNSIGNED) END) as avg_hold_time
                     FROM queue_log 
                     WHERE time > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 DAY))
                     GROUP BY queuename
                     HAVING (completed_calls + abandoned_calls) > 0
                     ORDER BY completed_calls DESC
                     LIMIT 10";
        
        $queueStats = $db->fetchAll($queueSql);
    } catch (Exception $e) {
        // queue_log table might not exist or might not be accessible
        $queueStats = [];
    }
    
    $response = [
        'status' => 'success',
        'timestamp' => time(),
        'server_time' => date('Y-m-d H:i:s'),
        'active_calls' => $activeCalls,
        'system_status' => $systemStatus,
        'recent_activity' => $recentStats,
        'queue_stats' => $queueStats
    ];
    
    echo json_encode($response, JSON_PRETTY_PRINT);

} catch (Exception $e) {
    http_response_code(500);
    echo json_encode([
        'status' => 'error',
        'message' => $e->getMessage(),
        'timestamp' => time()
    ]);
}
?>
EOF

    print_success "API real-time.php creada"
}

# Create API for data export
create_export_api() {
    print_status "Creando API export.php..."
    
    cat > "$DASHBOARD_DIR/api/export.php" << 'EOF'
<?php
/**
 * Export API
 * Exports call data in various formats
 */

require_once '../includes/CallReports.class.php';

try {
    $callReports = new CallReports();
    
    // Get parameters
    $dateStart = $_POST['date_start'] ?? $_GET['date_start'] ?? date('Y-m-d 00:00:00', strtotime('-30 days'));
    $dateEnd = $_POST['date_end'] ?? $_GET['date_end'] ?? date('Y-m-d 23:59:59');
    $extension = $_POST['extension'] ?? $_GET['extension'] ?? '';
    $format = strtolower($_POST['format'] ?? $_GET['format'] ?? 'csv');
    $maxRecords = min((int)($_POST['max_records'] ?? $_GET['max_records'] ?? 5000), 10000);
    
    // Validate format
    if (!in_array($format, ['csv', 'json'])) {
        throw new Exception('Invalid format. Supported: csv, json');
    }
    
    // Validate dates
    if (!DateTime::createFromFormat('Y-m-d H:i:s', $dateStart) || 
        !DateTime::createFromFormat('Y-m-d H:i:s', $dateEnd)) {
        throw new Exception('Invalid date format. Use Y-m-d H:i:s');
    }
    
    // Sanitize extension
    $extension = Settings::sanitizeInput($extension);
    
    // Get data
    $callDetails = $callReports->getCallDetails($dateStart, $dateEnd, $extension, $maxRecords, 0);
    
    if (empty($callDetails)) {
        throw new Exception('No data found for the specified criteria');
    }
    
    $filename = 'call_reports_' . date('Y-m-d_H-i-s');
    
    if ($format === 'csv') {
        // CSV Export
        header('Content-Type: text/csv; charset=utf-8');
        header('Content-Disposition: attachment; filename="' . $filename . '.csv"');
        header('Cache-Control: no-cache, must-revalidate');
        header('Expires: Sat, 26 Jul 1997 05:00:00 GMT');
        
        // Open output stream
        $output = fopen('php://output', 'w');
        
        // UTF-8 BOM for Excel compatibility
        fprintf($output, chr(0xEF).chr(0xBB).chr(0xBF));
        
        // CSV Headers
        $headers = [
            'Date/Time', 'Caller ID', 'Source', 'Destination', 
            'Context', 'Channel', 'Duration', 'Billable Duration', 
            'Disposition', 'Unique ID'
        ];
        fputcsv($output, $headers, Settings::CSV_DELIMITER, Settings::CSV_ENCLOSURE);
        
        // CSV Data
        foreach ($callDetails as $call) {
            $row = [
                $call['calldate'],
                $call['clid'],
                $call['src'],
                $call['dst'],
                $call['dcontext'],
                $call['channel'],
                $call['duration_formatted'],
                $call['billsec_formatted'],
                $call['disposition'],
                $call['uniqueid']
            ];
            fputcsv($output, $row, Settings::CSV_DELIMITER, Settings::CSV_ENCLOSURE);
        }
        
        fclose($output);
        
    } else if ($format === 'json') {
        // JSON Export
        header('Content-Type: application/json; charset=utf-8');
        header('Content-Disposition: attachment; filename="' . $filename . '.json"');
        header('Cache-Control: no-cache, must-revalidate');
        header('Expires: Sat, 26 Jul 1997 05:00:00 GMT');
        
        $exportData = [
            'export_info' => [
                'generated_at' => date('Y-m-d H:i:s'),
                'date_range' => [
                    'start' => $dateStart,
                    'end' => $dateEnd
                ],
                'extension_filter' => $extension,
                'format' => $format,
                'total_records' => count($callDetails)
            ],
            'call_data' => $callDetails
        ];
        
        echo json_encode($exportData, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);
    }

} catch (Exception $e) {
    // If headers not sent yet, send error response
    if (!headers_sent()) {
        header('Content-Type: application/json');
        http_response_code(400);
        echo json_encode([
            'status' => 'error',
            'message' => $e->getMessage(),
            'timestamp' => time()
        ]);
    } else {
        // Headers already sent, log error
        error_log("Export error: " . $e->getMessage());
    }
}
?>
EOF

    print_success "API export.php creada"
}

# Create API index/documentation
create_api_index() {
    print_status "Creando documentación de APIs..."
    
    cat > "$DASHBOARD_DIR/api/index.php" << 'EOF'
<?php
/**
 * API Documentation and Health Check
 */

header('Content-Type: application/json');

$apis = [
    'dashboard-data.php' => [
        'description' => 'Get comprehensive dashboard statistics',
        'method' => 'GET',
        'parameters' => [
            'date_start' => 'Start date (Y-m-d H:i:s format)',
            'date_end' => 'End date (Y-m-d H:i:s format)', 
            'extension' => 'Filter by extension (optional)'
        ]
    ],
    'call-details.php' => [
        'description' => 'Get detailed call records with pagination',
        'method' => 'GET',
        'parameters' => [
            'date_start' => 'Start date (Y-m-d H:i:s format)',
            'date_end' => 'End date (Y-m-d H:i:s format)',
            'extension' => 'Filter by extension (optional)',
            'limit' => 'Records per page (1-1000, default: 100)',
            'offset' => 'Pagination offset (default: 0)',
            'include_total' => 'Include total count (1/0, default: 0)'
        ]
    ],
    'real-time.php' => [
        'description' => 'Get real-time system status and activity',
        'method' => 'GET',
        'parameters' => []
    ],
    'export.php' => [
        'description' => 'Export call data in various formats',
        'method' => 'POST',
        'parameters' => [
            'date_start' => 'Start date (Y-m-d H:i:s format)',
            'date_end' => 'End date (Y-m-d H:i:s format)',
            'extension' => 'Filter by extension (optional)',
            'format' => 'Export format (csv/json)',
            'max_records' => 'Maximum records (default: 5000, max: 10000)'
        ]
    ]
];

// Test database connection
try {
    require_once '../includes/CallReports.class.php';
    $callReports = new CallReports();
    $dbStatus = $callReports->testConnection() ? 'connected' : 'disconnected';
} catch (Exception $e) {
    $dbStatus = 'error: ' . $e->getMessage();
}

$response = [
    'status' => 'ok',
    'timestamp' => time(),
    'dashboard_version' => '2.0.0',
    'database_status' => $dbStatus,
    'available_apis' => $apis,
    'example_urls' => [
        'Dashboard Data' => '../api/dashboard-data.php?date_start=' . date('Y-m-d 00:00:00', strtotime('-7 days')) . '&date_end=' . date('Y-m-d 23:59:59'),
        'Call Details' => '../api/call-details.php?limit=10',
        'Real-time Status' => '../api/real-time.php',
        'Export CSV' => '../api/export.php (POST method)'
    ]
];

echo json_encode($response, JSON_PRETTY_PRINT);
?>
EOF

    print_success "Documentación de APIs creada"
}
# Create main dashboard HTML file
create_main_html() {
    print_status "Creando index.html principal..."
    
    cat > "$DASHBOARD_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Call Reports Dashboard</title>
    <link rel="stylesheet" href="assets/css/dashboard.css">
    <link rel="icon" type="image/png" href="assets/images/favicon.png">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/3.9.1/chart.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/date-fns/2.29.3/index.min.js"></script>
</head>
<body>
    <div class="dashboard-container">
        <!-- Header -->
        <header class="dashboard-header">
            <div class="header-content">
                <h1 class="dashboard-title">
                    <span class="dashboard-icon">📊</span>
                    Call Reports Dashboard
                    <span class="version-badge">v2.0.0</span>
                </h1>
                <div class="header-actions">
                    <button id="real-time-toggle" class="btn btn-secondary">
                        <span class="btn-icon">⏱️</span>
                        Real Time
                    </button>
                    <button id="refresh-btn" class="btn btn-primary">
                        <span class="btn-icon">🔄</span>
                        Refresh
                    </button>
                </div>
            </div>
        </header>

        <!-- Real-time Status Bar -->
        <div id="realtime-status" class="realtime-status" style="display: none;">
            <div class="status-grid">
                <div class="status-item">
                    <span class="status-label">System Status:</span>
                    <span id="system-status" class="status-value">OK</span>
                </div>
                <div class="status-item">
                    <span class="status-label">Calls Last Hour:</span>
                    <span id="calls-last-hour" class="status-value">0</span>
                </div>
                <div class="status-item">
                    <span class="status-label">Last Call:</span>
                    <span id="last-call-time" class="status-value">--</span>
                </div>
                <div class="status-item">
                    <span class="status-label">Last Update:</span>
                    <span id="last-update" class="status-value">--</span>
                </div>
            </div>
        </div>

        <!-- Filters Panel -->
        <div class="filters-panel">
            <div class="filters-content">
                <div class="filter-group">
                    <label for="date_start">From:</label>
                    <input type="datetime-local" id="date_start" name="date_start">
                </div>
                <div class="filter-group">
                    <label for="date_end">To:</label>
                    <input type="datetime-local" id="date_end" name="date_end">
                </div>
                <div class="filter-group">
                    <label for="extension">Extension:</label>
                    <select id="extension" name="extension">
                        <option value="">All Extensions</option>
                    </select>
                </div>
                <div class="filter-actions">
                    <button id="filter-btn" class="btn btn-primary">
                        <span class="btn-icon">🔍</span>
                        Filter
                    </button>
                    <button id="export-btn" class="btn btn-success">
                        <span class="btn-icon">📄</span>
                        Export
                    </button>
                </div>
            </div>
        </div>

        <!-- Summary Cards -->
        <div class="summary-cards">
            <div class="card card-primary">
                <div class="card-header">
                    <h3>Total Calls</h3>
                    <span class="card-icon">📞</span>
                </div>
                <div class="card-body">
                    <div class="card-number" id="total-calls">--</div>
                    <div class="card-subtitle" id="total-calls-subtitle">Loading...</div>
                </div>
            </div>

            <div class="card card-success">
                <div class="card-header">
                    <h3>Answered Calls</h3>
                    <span class="card-icon">✅</span>
                </div>
                <div class="card-body">
                    <div class="card-number" id="answered-calls">--</div>
                    <div class="card-subtitle" id="answer-rate">--</div>
                </div>
            </div>

            <div class="card card-warning">
                <div class="card-header">
                    <h3>Average Duration</h3>
                    <span class="card-icon">⏰</span>
                </div>
                <div class="card-body">
                    <div class="card-number" id="avg-duration">--</div>
                    <div class="card-subtitle" id="total-duration">--</div>
                </div>
            </div>

            <div class="card card-danger">
                <div class="card-header">
                    <h3>Failed Calls</h3>
                    <span class="card-icon">❌</span>
                </div>
                <div class="card-body">
                    <div class="card-number" id="failed-calls">--</div>
                    <div class="card-subtitle" id="failure-rate">--</div>
                </div>
            </div>
        </div>

        <!-- Charts Section -->
        <div class="charts-section">
            <div class="chart-container">
                <div class="chart-header">
                    <h3>Daily Call Trends</h3>
                    <div class="chart-controls">
                        <button class="chart-btn" onclick="dashboard.toggleChartType('daily-chart')">
                            📊
                        </button>
                    </div>
                </div>
                <div class="chart-content">
                    <canvas id="daily-chart"></canvas>
                </div>
            </div>

            <div class="chart-container">
                <div class="chart-header">
                    <h3>Hourly Distribution</h3>
                    <div class="chart-controls">
                        <button class="chart-btn" onclick="dashboard.toggleChartType('hourly-chart')">
                            📊
                        </button>
                    </div>
                </div>
                <div class="chart-content">
                    <canvas id="hourly-chart"></canvas>
                </div>
            </div>
        </div>

        <!-- Data Tables Section -->
        <div class="tables-section">
            <div class="table-container">
                <div class="table-header">
                    <h3>Top Destinations</h3>
                    <div class="table-controls">
                        <input type="text" id="search-destinations" placeholder="Search destinations..." class="search-input">
                        <span class="record-count" id="destinations-count">0 records</span>
                    </div>
                </div>
                <div class="table-content">
                    <table id="destinations-table" class="data-table">
                        <thead>
                            <tr>
                                <th onclick="dashboard.sortTable('destinations', 'destination')">Destination ↕️</th>
                                <th onclick="dashboard.sortTable('destinations', 'call_count')">Calls ↕️</th>
                                <th onclick="dashboard.sortTable('destinations', 'answered_count')">Answered ↕️</th>
                                <th onclick="dashboard.sortTable('destinations', 'answer_rate')">Answer Rate ↕️</th>
                                <th onclick="dashboard.sortTable('destinations', 'total_duration')">Duration ↕️</th>
                            </tr>
                        </thead>
                        <tbody id="destinations-tbody">
                            <tr>
                                <td colspan="5" class="loading-cell">Loading data...</td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>

            <div class="table-container">
                <div class="table-header">
                    <h3>Extension Statistics</h3>
                    <div class="table-controls">
                        <input type="text" id="search-extensions" placeholder="Search extensions..." class="search-input">
                        <span class="record-count" id="extensions-count">0 records</span>
                    </div>
                </div>
                <div class="table-content">
                    <table id="extensions-table" class="data-table">
                        <thead>
                            <tr>
                                <th onclick="dashboard.sortTable('extensions', 'extension')">Extension ↕️</th>
                                <th onclick="dashboard.sortTable('extensions', 'call_count')">Calls ↕️</th>
                                <th onclick="dashboard.sortTable('extensions', 'answered_count')">Answered ↕️</th>
                                <th onclick="dashboard.sortTable('extensions', 'answer_rate')">Answer Rate ↕️</th>
                                <th onclick="dashboard.sortTable('extensions', 'avg_duration')">Avg Duration ↕️</th>
                                <th onclick="dashboard.sortTable('extensions', 'total_duration')">Total Duration ↕️</th>
                            </tr>
                        </thead>
                        <tbody id="extensions-tbody">
                            <tr>
                                <td colspan="6" class="loading-cell">Loading data...</td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <!-- Call Details Table -->
        <div class="table-container full-width">
            <div class="table-header">
                <h3>Recent Call Details</h3>
                <div class="table-controls">
                    <input type="text" id="search-calls" placeholder="Search calls..." class="search-input">
                    <button id="load-more-calls" class="btn btn-secondary">
                        <span class="btn-icon">⬇️</span>
                        Load More
                    </button>
                    <span class="record-count" id="calls-count">0 records</span>
                </div>
            </div>
            <div class="table-content">
                <table id="calls-table" class="data-table">
                    <thead>
                        <tr>
                            <th onclick="dashboard.sortTable('calls', 'calldate')">Date/Time ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'clid')">Caller ID ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'src')">Source ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'dst')">Destination ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'duration')">Duration ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'billsec')">Bill Duration ↕️</th>
                            <th onclick="dashboard.sortTable('calls', 'disposition')">Status ↕️</th>
                        </tr>
                    </thead>
                    <tbody id="calls-tbody">
                        <tr>
                            <td colspan="7" class="loading-cell">Loading call details...</td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Loading Overlay -->
        <div id="loading-overlay" class="loading-overlay" style="display: none;">
            <div class="loading-spinner">
                <div class="spinner"></div>
                <p>Loading dashboard data...</p>
            </div>
        </div>

        <!-- Export Modal -->
        <div id="export-modal" class="modal" style="display: none;">
            <div class="modal-content">
                <div class="modal-header">
                    <h3>Export Call Data</h3>
                    <span class="modal-close" onclick="dashboard.hideExportModal()">&times;</span>
                </div>
                <div class="modal-body">
                    <div class="form-group">
                        <label>Export Format:</label>
                        <div class="radio-group">
                            <label>
                                <input type="radio" name="export_format" value="csv" checked>
                                CSV (Excel compatible)
                            </label>
                            <label>
                                <input type="radio" name="export_format" value="json">
                                JSON (for developers)
                            </label>
                        </div>
                    </div>
                    <div class="form-group">
                        <label>Maximum Records:</label>
                        <select id="export_max_records">
                            <option value="1000">1,000 records</option>
                            <option value="5000" selected>5,000 records</option>
                            <option value="10000">10,000 records</option>
                        </select>
                    </div>
                    <div class="export-info">
                        <p><strong>Date Range:</strong> <span id="export-date-range">--</span></p>
                        <p><strong>Extension Filter:</strong> <span id="export-extension">All</span></p>
                    </div>
                </div>
                <div class="modal-footer">
                    <button id="confirm-export" class="btn btn-primary">
                        <span class="btn-icon">📄</span>
                        Download Export
                    </button>
                    <button class="btn btn-secondary" onclick="dashboard.hideExportModal()">
                        Cancel
                    </button>
                </div>
            </div>
        </div>

        <!-- Footer -->
        <footer class="dashboard-footer">
            <div class="footer-content">
                <p>Call Reports Dashboard v2.0.0 - Standalone Version</p>
                <div class="footer-links">
                    <a href="api/" target="_blank">API Documentation</a>
                    <span>|</span>
                    <span id="connection-status" class="connection-status">Connected</span>
                </div>
            </div>
        </footer>
    </div>

    <script src="assets/js/dashboard.js"></script>
    <script>
        // Initialize dashboard when page loads
        document.addEventListener('DOMContentLoaded', function() {
            dashboard.init();
        });
    </script>
</body>
</html>
EOF

    print_success "Archivo index.html creado"
}

# Create CSS stylesheet
create_css_stylesheet() {
    print_status "Creando dashboard.css..."
    
    cat > "$DASHBOARD_DIR/assets/css/dashboard.css" << 'EOF'
/* Call Reports Dashboard - Standalone CSS */
/* Modern, responsive design for all screen sizes */

:root {
    /* Color Palette */
    --primary-color: #667eea;
    --primary-dark: #5a6fd8;
    --secondary-color: #764ba2;
    --success-color: #28a745;
    --warning-color: #ffc107;
    --danger-color: #dc3545;
    --info-color: #17a2b8;
    --dark-color: #343a40;
    --light-color: #f8f9fa;
    
    /* Gradients */
    --gradient-primary: linear-gradient(135deg, var(--primary-color) 0%, var(--secondary-color) 100%);
    --gradient-success: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
    --gradient-warning: linear-gradient(135deg, #fcb045 0%, #fd1d1d 50%, #fcb045 100%);
    --gradient-info: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    
    /* Layout */
    --border-radius: 12px;
    --box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
    --box-shadow-hover: 0 8px 25px rgba(0, 0, 0, 0.15);
    --transition: all 0.3s ease;
    
    /* Typography */
    --font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    --font-size-base: 14px;
    --font-size-lg: 16px;
    --font-size-sm: 12px;
    --line-height: 1.6;
}

/* Reset and Base Styles */
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: var(--font-family);
    font-size: var(--font-size-base);
    line-height: var(--line-height);
    color: var(--dark-color);
    background-color: var(--light-color);
    overflow-x: hidden;
}

/* Dashboard Container */
.dashboard-container {
    max-width: 1400px;
    margin: 0 auto;
    padding: 20px;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
}

/* Header */
.dashboard-header {
    background: var(--gradient-primary);
    color: white;
    padding: 25px 30px;
    border-radius: var(--border-radius);
    box-shadow: var(--box-shadow);
    margin-bottom: 25px;
}

.header-content {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 15px;
}

.dashboard-title {
    font-size: 28px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 12px;
}

.dashboard-icon {
    font-size: 32px;
}

.version-badge {
    background: rgba(255, 255, 255, 0.2);
    padding: 4px 8px;
    border-radius: 6px;
    font-size: var(--font-size-sm);
    font-weight: 400;
}

.header-actions {
    display: flex;
    gap: 12px;
}

/* Buttons */
.btn {
    padding: 10px 20px;
    border: none;
    border-radius: 8px;
    cursor: pointer;
    font-size: var(--font-size-base);
    font-weight: 500;
    transition: var(--transition);
    display: inline-flex;
    align-items: center;
    gap: 8px;
    text-decoration: none;
    white-space: nowrap;
}

.btn:hover {
    transform: translateY(-2px);
    box-shadow: var(--box-shadow-hover);
}

.btn:active {
    transform: translateY(0);
}

.btn-primary {
    background-color: var(--primary-color);
    color: white;
}

.btn-secondary {
    background-color: #6c757d;
    color: white;
}

.btn-success {
    background-color: var(--success-color);
    color: white;
}

.btn-danger {
    background-color: var(--danger-color);
    color: white;
}

.btn-icon {
    font-size: 16px;
}

/* Real-time Status Bar */
.realtime-status {
    background: var(--gradient-success);
    color: white;
    padding: 20px;
    border-radius: var(--border-radius);
    margin-bottom: 25px;
    animation: pulse 2s infinite;
}

@keyframes pulse {
    0% { box-shadow: 0 0 0 0 rgba(56, 239, 125, 0.4); }
    70% { box-shadow: 0 0 0 10px rgba(56, 239, 125, 0); }
    100% { box-shadow: 0 0 0 0 rgba(56, 239, 125, 0); }
}

.status-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 20px;
}

.status-item {
    text-align: center;
}

.status-label {
    display: block;
    font-size: var(--font-size-sm);
    opacity: 0.9;
    margin-bottom: 8px;
    font-weight: 400;
}

.status-value {
    display: block;
    font-size: 18px;
    font-weight: 600;
}

/* Filters Panel */
.filters-panel {
    background: white;
    padding: 25px;
    border-radius: var(--border-radius);
    box-shadow: var(--box-shadow);
    margin-bottom: 30px;
}

.filters-content {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    align-items: end;
}

.filter-group {
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-width: 150px;
}

.filter-group label {
    font-weight: 500;
    color: #555;
    font-size: var(--font-size-base);
}

.filter-group input,
.filter-group select {
    padding: 10px 12px;
    border: 2px solid #e9ecef;
    border-radius: 6px;
    font-size: var(--font-size-base);
    transition: border-color 0.3s ease;
    background-color: white;
}

.filter-group input:focus,
.filter-group select:focus {
    outline: none;
    border-color: var(--primary-color);
    box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
}

.filter-actions {
    display: flex;
    gap: 12px;
}

/* Summary Cards */
.summary-cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 25px;
    margin-bottom: 35px;
}

.card {
    background: white;
    border-radius: var(--border-radius);
    overflow: hidden;
    box-shadow: var(--box-shadow);
    transition: var(--transition);
}

.card:hover {
    transform: translateY(-5px);
    box-shadow: var(--box-shadow-hover);
}

.card-header {
    padding: 20px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    color: white;
    font-weight: 600;
}

.card-primary .card-header {
    background: var(--gradient-primary);
}

.card-success .card-header {
    background: var(--gradient-success);
}

.card-warning .card-header {
    background: linear-gradient(135deg, #fcb045 0%, #fd7e14 100%);
}

.card-danger .card-header {
    background: linear-gradient(135deg, #dc3545 0%, #c82333 100%);
}

.card-icon {
    font-size: 24px;
    opacity: 0.8;
}

.card-body {
    padding: 25px 20px;
    text-align: center;
}

.card-number {
    font-size: 42px;
    font-weight: 700;
    color: var(--dark-color);
    margin-bottom: 10px;
    line-height: 1;
}

.card-subtitle {
    font-size: var(--font-size-base);
    color: #666;
    font-weight: 500;
}

/* Charts Section */
.charts-section {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
    gap: 25px;
    margin-bottom: 35px;
}

.chart-container {
    background: white;
    border-radius: var(--border-radius);
    padding: 25px;
    box-shadow: var(--box-shadow);
}

.chart-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 25px;
    padding-bottom: 15px;
    border-bottom: 2px solid var(--light-color);
}

.chart-header h3 {
    color: var(--dark-color);
    font-weight: 600;
}

.chart-controls {
    display: flex;
    gap: 8px;
}

.chart-btn {
    background: var(--light-color);
    border: none;
    padding: 8px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 16px;
    transition: var(--transition);
}

.chart-btn:hover {
    background: #e9ecef;
    transform: scale(1.1);
}

.chart-content {
    position: relative;
    height: 350px;
}

/* Tables Section */
.tables-section {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(600px, 1fr));
    gap: 25px;
    margin-bottom: 35px;
}

.table-container {
    background: white;
    border-radius: var(--border-radius);
    overflow: hidden;
    box-shadow: var(--box-shadow);
}

.table-container.full-width {
    grid-column: 1 / -1;
}

.table-header {
    background: var(--gradient-primary);
    color: white;
    padding: 20px 25px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 15px;
}

.table-header h3 {
    font-weight: 600;
    margin: 0;
}

.table-controls {
    display: flex;
    gap: 15px;
    align-items: center;
    flex-wrap: wrap;
}

.search-input {
    padding: 8px 12px;
    border: none;
    border-radius: 6px;
    font-size: var(--font-size-base);
    background: rgba(255, 255, 255, 0.2);
    color: white;
    min-width: 200px;
}

.search-input::placeholder {
    color: rgba(255, 255, 255, 0.7);
}

.search-input:focus {
    outline: none;
    background: rgba(255, 255, 255, 0.3);
}

.record-count {
    font-size: var(--font-size-sm);
    opacity: 0.8;
}

.table-content {
    max-height: 500px;
    overflow-y: auto;
}

.data-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--font-size-base);
}

.data-table th {
    background-color: var(--light-color);
    padding: 15px 12px;
    text-align: left;
    font-weight: 600;
    color: #555;
    border-bottom: 2px solid #dee2e6;
    position: sticky;
    top: 0;
    z-index: 10;
    cursor: pointer;
    transition: background-color 0.2s ease;
}

.data-table th:hover {
    background-color: #e9ecef;
}

.data-table td {
    padding: 12px;
    border-bottom: 1px solid #dee2e6;
    transition: background-color 0.2s ease;
}

.data-table tbody tr:hover {
    background-color: var(--light-color);
}

.loading-cell {
    text-align: center;
    color: #666;
    font-style: italic;
    padding: 40px !important;
}

/* Status Indicators */
.status-indicator {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 8px;
}

.status-answered { background-color: var(--success-color); }
.status-no-answer { background-color: var(--warning-color); }
.status-failed { background-color: var(--danger-color); }
.status-busy { background-color: #fd7e14; }

/* Loading Overlay */
.loading-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    justify-content: center;
    align-items: center;
    z-index: 9999;
}

.loading-spinner {
    background: white;
    padding: 40px;
    border-radius: var(--border-radius);
    text-align: center;
    box-shadow: var(--box-shadow-hover);
}

.spinner {
    width: 50px;
    height: 50px;
    border: 5px solid var(--light-color);
    border-top: 5px solid var(--primary-color);
    border-radius: 50%;
    animation: spin 1s linear infinite;
    margin: 0 auto 20px;
}

@keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
}

/* Modal */
.modal {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    justify-content: center;
    align-items: center;
    z-index: 10000;
}

.modal-content {
    background: white;
    border-radius: var(--border-radius);
    max-width: 500px;
    width: 90%;
    max-height: 90vh;
    overflow-y: auto;
    box-shadow: var(--box-shadow-hover);
}

.modal-header {
    background: var(--gradient-primary);
    color: white;
    padding: 20px 25px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.modal-close {
    cursor: pointer;
    font-size: 28px;
    line-height: 1;
    opacity: 0.8;
    transition: var(--transition);
}

.modal-close:hover {
    opacity: 1;
    transform: scale(1.1);
}

.modal-body {
    padding: 25px;
}

.modal-footer {
    padding: 20px 25px;
    border-top: 1px solid #dee2e6;
    display: flex;
    justify-content: flex-end;
    gap: 12px;
}

.form-group {
    margin-bottom: 20px;
}

.form-group label {
    display: block;
    font-weight: 500;
    margin-bottom: 8px;
    color: var(--dark-color);
}

.radio-group {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.radio-group label {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 400;
    cursor: pointer;
}

.export-info {
    background: var(--light-color);
    padding: 15px;
    border-radius: 6px;
    margin-top: 15px;
}

.export-info p {
    margin-bottom: 5px;
}

/* Footer */
.dashboard-footer {
    margin-top: auto;
    background: white;
    padding: 20px;
    border-radius: var(--border-radius);
    box-shadow: var(--box-shadow);
    text-align: center;
}

.footer-content {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 15px;
}

.footer-links {
    display: flex;
    gap: 15px;
    align-items: center;
}

.footer-links a {
    color: var(--primary-color);
    text-decoration: none;
    font-weight: 500;
    transition: var(--transition);
}

.footer-links a:hover {
    color: var(--primary-dark);
    text-decoration: underline;
}

.connection-status {
    padding: 4px 8px;
    border-radius: 4px;
    font-size: var(--font-size-sm);
    font-weight: 500;
}

.connection-status.connected {
    background: #d4edda;
    color: #155724;
}

.connection-status.disconnected {
    background: #f8d7da;
    color: #721c24;
}

/* Responsive Design */
@media (max-width: 1200px) {
    .charts-section {
        grid-template-columns: 1fr;
    }
}

@media (max-width: 768px) {
    .dashboard-container {
        padding: 15px;
    }
    
    .header-content {
        flex-direction: column;
        text-align: center;
    }
    
    .dashboard-title {
        font-size: 24px;
    }
    
    .filters-content {
        flex-direction: column;
        align-items: stretch;
    }
    
    .filter-actions {
        justify-content: center;
    }
    
    .summary-cards {
        grid-template-columns: 1fr;
    }
    
    .charts-section {
        grid-template-columns: 1fr;
    }
    
    .tables-section {
        grid-template-columns: 1fr;
    }
    
    .table-header {
        flex-direction: column;
        align-items: stretch;
        gap: 10px;
    }
    
    .table-controls {
        justify-content: space-between;
    }
    
    .search-input {
        min-width: auto;
        flex: 1;
    }
    
    .footer-content {
        flex-direction: column;
        text-align: center;
    }
}

@media (max-width: 480px) {
    .dashboard-container {
        padding: 10px;
    }
    
    .card-number {
        font-size: 32px;
    }
    
    .chart-content {
        height: 250px;
    }
    
    .data-table th,
    .data-table td {
        padding: 8px;
        font-size: var(--font-size-sm);
    }
}

/* Print Styles */
@media print {
    .dashboard-header,
    .filters-panel,
    .header-actions,
    .table-controls,
    .loading-overlay,
    .modal,
    .dashboard-footer {
        display: none !important;
    }
    
    .dashboard-container {
        padding: 0;
        max-width: none;
    }
    
    .card {
        break-inside: avoid;
        box-shadow: none;
        border: 1px solid #ddd;
    }
    
    .table-content {
        max-height: none;
        overflow: visible;
    }
}

/* Accessibility */
@media (prefers-reduced-motion: reduce) {
    * {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
    }
    
    .realtime-status {
        animation: none;
    }
}

/* High Contrast Mode */
@media (prefers-contrast: high) {
    :root {
        --box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
        --box-shadow-hover: 0 8px 25px rgba(0, 0, 0, 0.4);
    }
    
    .data-table th {
        border-bottom: 3px solid #000;
    }
    
    .data-table td {
        border-bottom: 2px solid #666;
    }
}

/* Dark mode support (optional) */
@media (prefers-color-scheme: dark) {
    :root {
        --dark-color: #ffffff;
        --light-color: #1a1a1a;
    }
    
    body {
        background-color: #121212;
        color: #ffffff;
    }
    
    .card,
    .filters-panel,
    .chart-container,
    .table-container {
        background: #1e1e1e;
        color: #ffffff;
    }
    
    .data-table th {
        background-color: #2a2a2a;
        color: #ffffff;
    }
}
EOF

    print_success "Archivo dashboard.css creado"
}
# Create JavaScript file
create_javascript_file() {
    print_status "Creando dashboard.js..."
    
    cat > "$DASHBOARD_DIR/assets/js/dashboard.js" << 'EOF'
	/**
 * Call Reports Dashboard - JavaScript Controller
 * Standalone version with no external dependencies except Chart.js
 */

const dashboard = {
    // Configuration
    config: {
        apiUrl: './api/',
        refreshInterval: 30000, // 30 seconds
        realTimeInterval: 5000, // 5 seconds
        chartColors: [
            '#667eea', '#764ba2', '#f093fb', '#f5576c',
            '#4facfe', '#00f2fe', '#43e97b', '#38f9d7',
            '#ffecd2', '#fcb69f', '#a8edea', '#fed6e3'
        ],
        maxRetries: 3,
        retryDelay: 2000
    },

    // State
    state: {
        charts: {},
        realTimeActive: false,
        realTimeTimer: null,
        refreshTimer: null,
        currentData: {},
        sortState: {},
        currentCallsOffset: 0,
        retryCount: 0
    },

    // Initialize dashboard
    init() {
        console.log('Initializing Call Reports Dashboard v2.0.0');
        this.setupEventListeners();
        this.initializeDateInputs();
        this.loadExtensions();
        this.loadDashboardData();
        this.setupCharts();
        this.startAutoRefresh();
        this.checkConnection();
    },

    // Setup event listeners
    setupEventListeners() {
        // Filter controls
        document.getElementById('filter-btn').addEventListener('click', () => {
            this.loadDashboardData();
        });

        document.getElementById('refresh-btn').addEventListener('click', () => {
            this.refreshDashboard();
        });

        document.getElementById('real-time-toggle').addEventListener('click', () => {
            this.toggleRealTime();
        });

        // Export functionality
        document.getElementById('export-btn').addEventListener('click', () => {
            this.showExportModal();
        });

        document.getElementById('confirm-export').addEventListener('click', () => {
            this.performExport();
        });

        // Load more calls
        document.getElementById('load-more-calls').addEventListener('click', () => {
            this.loadMoreCalls();
        });

        // Search functionality
        document.getElementById('search-destinations').addEventListener('keyup', (e) => {
            this.filterTable('destinations-table', e.target.value);
        });

        document.getElementById('search-extensions').addEventListener('keyup', (e) => {
            this.filterTable('extensions-table', e.target.value);
        });

        document.getElementById('search-calls').addEventListener('keyup', (e) => {
            this.filterTable('calls-table', e.target.value);
        });

        // Auto-refresh on date/extension change
        ['date_start', 'date_end', 'extension'].forEach(id => {
            const element = document.getElementById(id);
            if (element) {
                element.addEventListener('change', () => {
                    clearTimeout(this.debounceTimer);
                    this.debounceTimer = setTimeout(() => {
                        this.loadDashboardData();
                    }, 1000);
                });
            }
        });

        // Close modal when clicking outside
        document.addEventListener('click', (e) => {
            const modal = document.getElementById('export-modal');
            if (e.target === modal) {
                this.hideExportModal();
            }
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                this.hideExportModal();
            }
            if (e.ctrlKey && e.key === 'r') {
                e.preventDefault();
                this.refreshDashboard();
            }
        });
    },

    // Initialize date inputs with default values
    initializeDateInputs() {
        const now = new Date();
        const startDate = new Date();
        startDate.setDate(now.getDate() - 30);

        const formatForInput = (date) => {
            const year = date.getFullYear();
            const month = String(date.getMonth() + 1).padStart(2, '0');
            const day = String(date.getDate()).padStart(2, '0');
            const hours = String(date.getHours()).padStart(2, '0');
            const minutes = String(date.getMinutes()).padStart(2, '0');
            return `${year}-${month}-${day}T${hours}:${minutes}`;
        };

        document.getElementById('date_start').value = formatForInput(startDate);
        document.getElementById('date_end').value = formatForInput(now);
    },

    // Load available extensions
    async loadExtensions() {
        try {
            const response = await this.apiRequest('dashboard-data.php?extension_list=1');
            if (response && response.extensions) {
                const select = document.getElementById('extension');
                select.innerHTML = '<option value="">All Extensions</option>';
                
                Object.entries(response.extensions).forEach(([value, label]) => {
                    if (value) {
                        const option = document.createElement('option');
                        option.value = value;
                        option.textContent = label;
                        select.appendChild(option);
                    }
                });
            }
        } catch (error) {
            console.warn('Could not load extensions:', error);
        }
    },

    // Load main dashboard data
    async loadDashboardData() {
        this.showLoading(true);
        
        try {
            const params = this.getFilterParams();
            const url = `dashboard-data.php?${new URLSearchParams(params).toString()}`;
            
            const data = await this.apiRequest(url);
            
            if (data && data.status === 'success') {
                this.state.currentData = data;
                this.updateSummaryCards(data.call_summary);
                this.updateCharts(data);
                this.updateTables(data);
                this.loadCallDetails();
                this.state.retryCount = 0; // Reset retry count on success
            } else {
                throw new Error(data?.message || 'Invalid response format');
            }
        } catch (error) {
            console.error('Failed to load dashboard data:', error);
            this.showError('Failed to load dashboard data: ' + error.message);
            this.handleConnectionError();
        } finally {
            this.showLoading(false);
        }
    },

    // Load call details with pagination
    async loadCallDetails(offset = 0) {
        try {
            const params = {
                ...this.getFilterParams(),
                limit: 50,
                offset: offset
            };
            
            const url = `call-details.php?${new URLSearchParams(params).toString()}`;
            const response = await this.apiRequest(url);
            
            if (response && response.status === 'success') {
                this.updateCallsTable(response.data, offset > 0);
                this.state.currentCallsOffset = offset;
            }
        } catch (error) {
            console.error('Failed to load call details:', error);
        }
    },

    // Setup Chart.js charts
    setupCharts() {
        // Daily trends chart
        const dailyCtx = document.getElementById('daily-chart');
        if (dailyCtx) {
            this.state.charts.daily = new Chart(dailyCtx, {
                type: 'line',
                data: {
                    labels: [],
                    datasets: [{
                        label: 'Total Calls',
                        data: [],
                        borderColor: this.config.chartColors[0],
                        backgroundColor: this.config.chartColors[0] + '20',
                        borderWidth: 3,
                        tension: 0.4,
                        fill: true
                    }, {
                        label: 'Answered Calls',
                        data: [],
                        borderColor: this.config.chartColors[6],
                        backgroundColor: this.config.chartColors[6] + '20',
                        borderWidth: 2,
                        tension: 0.4
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: true,
                            position: 'top'
                        },
                        tooltip: {
                            mode: 'index',
                            intersect: false
                        }
                    },
                    scales: {
                        x: {
                            display: true,
                            title: {
                                display: true,
                                text: 'Date'
                            }
                        },
                        y: {
                            display: true,
                            title: {
                                display: true,
                                text: 'Number of Calls'
                            },
                            beginAtZero: true
                        }
                    },
                    interaction: {
                        mode: 'nearest',
                        axis: 'x',
                        intersect: false
                    }
                }
            });
        }

        // Hourly distribution chart
        const hourlyCtx = document.getElementById('hourly-chart');
        if (hourlyCtx) {
            this.state.charts.hourly = new Chart(hourlyCtx, {
                type: 'bar',
                data: {
                    labels: Array.from({length: 24}, (_, i) => `${i}:00`),
                    datasets: [{
                        label: 'Calls by Hour',
                        data: new Array(24).fill(0),
                        backgroundColor: this.config.chartColors[1],
                        borderColor: this.config.chartColors[1],
                        borderWidth: 1
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: false
                        },
                        tooltip: {
                            callbacks: {
                                title: function(tooltipItems) {
                                    return `Hour ${tooltipItems[0].label}`;
                                }
                            }
                        }
                    },
                    scales: {
                        x: {
                            title: {
                                display: true,
                                text: 'Hour of Day'
                            }
                        },
                        y: {
                            title: {
                                display: true,
                                text: 'Number of Calls'
                            },
                            beginAtZero: true
                        }
                    }
                }
            });
        }
    },

    // Update summary cards
    updateSummaryCards(data) {
        if (!data) return;

        this.updateElement('total-calls', this.formatNumber(data.total_calls || 0));
        this.updateElement('answered-calls', this.formatNumber(data.answered_calls || 0));
        this.updateElement('failed-calls', this.formatNumber(data.failed_calls || 0));
        this.updateElement('avg-duration', data.avg_duration_formatted || '00:00:00');

        this.updateElement('answer-rate', `${data.answer_rate || 0}%`);
        this.updateElement('total-calls-subtitle', `Period Total`);
        this.updateElement('total-duration', `Total: ${data.total_duration_formatted || '00:00:00'}`);
        this.updateElement('failure-rate', `${((data.failed_calls / data.total_calls) * 100 || 0).toFixed(1)}%`);
    },

    // Update charts with new data
    updateCharts(data) {
        // Update daily trends chart
        if (this.state.charts.daily && data.daily_trends) {
            const labels = data.daily_trends.map(item => {
                const date = new Date(item.call_date);
                return date.toLocaleDateString();
            });
            const totalCalls = data.daily_trends.map(item => item.call_count);
            const answeredCalls = data.daily_trends.map(item => item.answered_count);

            this.state.charts.daily.data.labels = labels;
            this.state.charts.daily.data.datasets[0].data = totalCalls;
            this.state.charts.daily.data.datasets[1].data = answeredCalls;
            this.state.charts.daily.update();
        }

        // Update hourly distribution chart
        if (this.state.charts.hourly && data.hourly_distribution) {
            const hourlyData = new Array(24).fill(0);
            
            data.hourly_distribution.forEach(item => {
                if (item.hour >= 0 && item.hour < 24) {
                    hourlyData[item.hour] = item.call_count;
                }
            });

            this.state.charts.hourly.data.datasets[0].data = hourlyData;
            this.state.charts.hourly.update();
        }
    },

    // Update data tables
    updateTables(data) {
        if (data.top_destinations) {
            this.updateDestinationsTable(data.top_destinations);
        }

        if (data.extension_stats) {
            this.updateExtensionsTable(data.extension_stats);
        }
    },

    // Update destinations table
    updateDestinationsTable(data) {
        const tbody = document.getElementById('destinations-tbody');
        const count = document.getElementById('destinations-count');
        
        if (!tbody) return;

        tbody.innerHTML = '';
        
        if (data && data.length > 0) {
            data.forEach(item => {
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${this.escapeHtml(item.destination)}</td>
                    <td>${this.formatNumber(item.call_count)}</td>
                    <td>${this.formatNumber(item.answered_count)}</td>
                    <td>${item.answer_rate}%</td>
                    <td>${item.total_duration_formatted || '00:00:00'}</td>
                `;
                tbody.appendChild(row);
            });
            if (count) count.textContent = `${data.length} records`;
        } else {
            tbody.innerHTML = '<tr><td colspan="5" class="loading-cell">No data available</td></tr>';
            if (count) count.textContent = '0 records';
        }
    },

    // Update extensions table
    updateExtensionsTable(data) {
        const tbody = document.getElementById('extensions-tbody');
        const count = document.getElementById('extensions-count');
        
        if (!tbody) return;

        tbody.innerHTML = '';
        
        if (data && data.length > 0) {
            data.forEach(item => {
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${this.escapeHtml(item.extension)}</td>
                    <td>${this.formatNumber(item.call_count)}</td>
                    <td>${this.formatNumber(item.answered_count)}</td>
                    <td>${item.answer_rate}%</td>
                    <td>${item.avg_duration_formatted || '00:00:00'}</td>
                    <td>${item.total_duration_formatted || '00:00:00'}</td>
                `;
                tbody.appendChild(row);
            });
            if (count) count.textContent = `${data.length} records`;
        } else {
            tbody.innerHTML = '<tr><td colspan="6" class="loading-cell">No data available</td></tr>';
            if (count) count.textContent = '0 records';
        }
    },

    // Update calls table
    updateCallsTable(data, append = false) {
        const tbody = document.getElementById('calls-tbody');
        const count = document.getElementById('calls-count');
        
        if (!tbody) return;

        if (!append) {
            tbody.innerHTML = '';
        }

        if (data && data.length > 0) {
            data.forEach(item => {
                const row = document.createElement('tr');
                const statusClass = this.getStatusClass(item.disposition);
                
                row.innerHTML = `
                    <td>${this.formatDateTime(item.calldate)}</td>
                    <td>${this.escapeHtml(item.clid || '')}</td>
                    <td>${this.escapeHtml(item.src)}</td>
                    <td>${this.escapeHtml(item.dst)}</td>
                    <td>${item.duration_formatted}</td>
                    <td>${item.billsec_formatted}</td>
                    <td><span class="status-indicator ${statusClass}"></span>${item.disposition}</td>
                `;
                tbody.appendChild(row);
            });
            
            const totalRows = tbody.children.length;
            if (count) count.textContent = `${totalRows} records`;
        } else if (!append) {
            tbody.innerHTML = '<tr><td colspan="7" class="loading-cell">No call details available</td></tr>';
            if (count) count.textContent = '0 records';
        }
    },

    // API request helper with retry logic
    async apiRequest(endpoint, options = {}) {
        const url = this.config.apiUrl + endpoint;
        const defaultOptions = {
            headers: {
                'Content-Type': 'application/json'
            }
        };

        try {
            const response = await fetch(url, { ...defaultOptions, ...options });
            
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }

            const data = await response.json();
            this.updateConnectionStatus(true);
            return data;
        } catch (error) {
            this.updateConnectionStatus(false);
            
            // Retry logic
            if (this.state.retryCount < this.config.maxRetries) {
                this.state.retryCount++;
                console.log(`Retrying API request (${this.state.retryCount}/${this.config.maxRetries})...`);
                await this.sleep(this.config.retryDelay * this.state.retryCount);
                return this.apiRequest(endpoint, options);
            }
            
            throw error;
        }
    },

    // Utility functions
    formatNumber(num) {
        if (num === null || num === undefined) return '0';
        return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    },

    formatDateTime(dateStr) {
        const date = new Date(dateStr);
        return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
    },

    escapeHtml(unsafe) {
        return unsafe
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#039;");
    },

    getStatusClass(disposition) {
        switch (disposition) {
            case 'ANSWERED': return 'status-answered';
            case 'NO ANSWER': return 'status-no-answer';
            case 'BUSY': return 'status-busy';
            default: return 'status-failed';
        }
    },

    updateElement(id, content) {
        const element = document.getElementById(id);
        if (element) {
            element.textContent = content;
        }
    },

    sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    },

    // Get current filter parameters
    getFilterParams() {
        const dateStart = document.getElementById('date_start').value.replace('T', ' ') + ':00';
        const dateEnd = document.getElementById('date_end').value.replace('T', ' ') + ':59';
        const extension = document.getElementById('extension').value;

        return {
            date_start: dateStart,
            date_end: dateEnd,
            extension: extension
        };
    },

    // Show/hide loading overlay
    showLoading(show) {
        const overlay = document.getElementById('loading-overlay');
        if (overlay) {
            overlay.style.display = show ? 'flex' : 'none';
        }
    },

    // Show error message
    showError(message) {
        console.error(message);
        alert('Error: ' + message);
    },

    // Refresh entire dashboard
    refreshDashboard() {
        console.log('Refreshing dashboard...');
        this.state.currentCallsOffset = 0;
        this.loadDashboardData();
    },

    // Toggle real-time updates
    toggleRealTime() {
        const button = document.getElementById('real-time-toggle');
        const status = document.getElementById('realtime-status');
        
        if (this.state.realTimeActive) {
            // Disable real-time
            clearInterval(this.state.realTimeTimer);
            this.state.realTimeActive = false;
            button.innerHTML = '<span class="btn-icon">⏱️</span>Real Time';
            button.className = 'btn btn-secondary';
            status.style.display = 'none';
        } else {
            // Enable real-time
            this.state.realTimeActive = true;
            button.innerHTML = '<span class="btn-icon">⏸️</span>Real Time ON';
            button.className = 'btn btn-success';
            status.style.display = 'block';
            
            this.updateRealTimeData(); // Initial update
            this.state.realTimeTimer = setInterval(() => {
                this.updateRealTimeData();
            }, this.config.realTimeInterval);
        }
    },

    // Update real-time data
    async updateRealTimeData() {
        try {
            const data = await this.apiRequest('real-time.php');
            
            if (data && data.status === 'success') {
                this.updateElement('system-status', data.system_status.database_status === 'connected' ? 'OK' : 'ERROR');
                this.updateElement('calls-last-hour', data.recent_activity.total_calls || 0);
                this.updateElement('last-call-time', data.system_status.last_call_time ? 
                    this.formatDateTime(data.system_status.last_call_time) : 'N/A');
                this.updateElement('last-update', new Date().toLocaleTimeString());
            }
        } catch (error) {
            console.error('Failed to update real-time data:', error);
        }
    },

    // Start auto-refresh timer
    startAutoRefresh() {
        this.state.refreshTimer = setInterval(() => {
            if (!this.state.realTimeActive) {
                this.loadDashboardData();
            }
        }, this.config.refreshInterval);
    },

    // Connection status management
    updateConnectionStatus(connected) {
        const statusElement = document.getElementById('connection-status');
        if (statusElement) {
            statusElement.textContent = connected ? 'Connected' : 'Disconnected';
            statusElement.className = `connection-status ${connected ? 'connected' : 'disconnected'}`;
        }
    },

    handleConnectionError() {
        if (this.state.retryCount >= this.config.maxRetries) {
            this.showError('Connection lost. Please check your network connection.');
        }
    },

    async checkConnection() {
        try {
            await this.apiRequest('index.php');
            this.updateConnectionStatus(true);
        } catch (error) {
            this.updateConnectionStatus(false);
        }
    },

    // Export functionality
    showExportModal() {
        const modal = document.getElementById('export-modal');
        const params = this.getFilterParams();
        
        document.getElementById('export-date-range').textContent = 
            `${params.date_start} to ${params.date_end}`;
        document.getElementById('export-extension').textContent = 
            params.extension || 'All Extensions';
            
        modal.style.display = 'flex';
    },

    hideExportModal() {
        document.getElementById('export-modal').style.display = 'none';
    },

    async performExport() {
        const format = document.querySelector('input[name="export_format"]:checked').value;
        const maxRecords = document.getElementById('export_max_records').value;
        const params = this.getFilterParams();
        
        try {
            const formData = new FormData();
            formData.append('date_start', params.date_start);
            formData.append('date_end', params.date_end);
            formData.append('extension', params.extension);
            formData.append('format', format);
            formData.append('max_records', maxRecords);
            
            const response = await fetch(this.config.apiUrl + 'export.php', {
                method: 'POST',
                body: formData
            });
            
            if (response.ok) {
                const blob = await response.blob();
                const url = window.URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.style.display = 'none';
                a.href = url;
                a.download = `call_reports_${new Date().toISOString().split('T')[0]}.${format}`;
                document.body.appendChild(a);
                a.click();
                window.URL.revokeObjectURL(url);
                document.body.removeChild(a);
                
                this.hideExportModal();
            } else {
                throw new Error('Export failed');
            }
        } catch (error) {
            console.error('Export error:', error);
            this.showError('Export failed: ' + error.message);
        }
    },

    // Load more call details
    loadMoreCalls() {
        const newOffset = this.state.currentCallsOffset + 50;
        this.loadCallDetails(newOffset);
    },

    // Table filtering
    filterTable(tableId, searchValue) {
        const table = document.getElementById(tableId);
        if (!table) return;
        
        const rows = table.getElementsByTagName('tbody')[0].getElementsByTagName('tr');
        searchValue = searchValue.toLowerCase();
        
        let visibleCount = 0;
        Array.from(rows).forEach(row => {
            const text = row.textContent.toLowerCase();
            if (text.includes(searchValue)) {
                row.style.display = '';
                visibleCount++;
            } else {
                row.style.display = 'none';
            }
        });
        
        // Update record count if available
        const countId = tableId.replace('-table', '-count');
        const countElement = document.getElementById(countId);
        if (countElement && searchValue) {
            countElement.textContent = `${visibleCount} filtered records`;
        }
    },

    // Table sorting
    sortTable(tableType, column) {
        const tableId = `${tableType}-table`;
        const table = document.getElementById(tableId);
        if (!table) return;
        
        const tbody = table.getElementsByTagName('tbody')[0];
        const rows = Array.from(tbody.getElementsByTagName('tr'));
        
        // Get current sort state
        const currentSort = this.state.sortState[tableType] || {};
        const isAsc = currentSort.column === column ? !currentSort.ascending : true;
        
        // Update sort state
        this.state.sortState[tableType] = { column, ascending: isAsc };
        
        // Sort rows
        rows.sort((a, b) => {
            const aVal = this.getCellValue(a, column);
            const bVal = this.getCellValue(b, column);
            
            if (aVal === bVal) return 0;
            
            const comparison = aVal > bVal ? 1 : -1;
            return isAsc ? comparison : -comparison;
        });
        
        // Rebuild table
        rows.forEach(row => tbody.appendChild(row));
    },

    // Get cell value for sorting
    getCellValue(row, column) {
        const cells = row.getElementsByTagName('td');
        const cellIndex = this.getColumnIndex(column);
        
        if (cellIndex >= 0 && cellIndex < cells.length) {
            const text = cells[cellIndex].textContent.trim();
            
            // Try to parse as number
            const num = parseFloat(text.replace(/[,%]/g, ''));
            if (!isNaN(num)) return num;
            
            // Try to parse as date
            const date = Date.parse(text);
            if (!isNaN(date)) return date;
            
            return text.toLowerCase();
        }
        
        return '';
    },

    // Get column index for sorting
    getColumnIndex(column) {
        const columnMappings = {
            // Destinations table
            destination: 0, call_count: 1, answered_count: 2, answer_rate: 3, total_duration: 4,
            // Extensions table  
            extension: 0, avg_duration: 4,
            // Calls table
            calldate: 0, clid: 1, src: 2, dst: 3, duration: 4, billsec: 5, disposition: 6
        };
        
        return columnMappings[column] || 0;
    },

    // Toggle chart type
    toggleChartType(chartId) {
        const chart = this.state.charts[chartId.replace('-chart', '')];
        if (!chart) return;
        
        // Toggle between line and bar for daily chart
        if (chartId === 'daily-chart') {
            chart.config.type = chart.config.type === 'line' ? 'bar' : 'line';
            chart.update();
        }
        // Toggle between bar and doughnut for hourly chart
        else if (chartId === 'hourly-chart') {
            chart.config.type = chart.config.type === 'bar' ? 'doughnut' : 'bar';
            chart.update();
        }
    },

    // Cleanup when page unloads
    cleanup() {
        if (this.state.realTimeTimer) {
            clearInterval(this.state.realTimeTimer);
        }
        if (this.state.refreshTimer) {
            clearInterval(this.state.refreshTimer);
        }
        
        // Destroy charts
        Object.values(this.state.charts).forEach(chart => {
            if (chart && typeof chart.destroy === 'function') {
                chart.destroy();
            }
        });
    }
};

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    dashboard.cleanup();
});

// Handle visibility change (pause updates when tab is hidden)
document.addEventListener('visibilitychange', () => {
    if (document.hidden && dashboard.state.realTimeActive) {
        clearInterval(dashboard.state.realTimeTimer);
    } else if (!document.hidden && dashboard.state.realTimeActive) {
        dashboard.state.realTimeTimer = setInterval(() => {
            dashboard.updateRealTimeData();
        }, dashboard.config.realTimeInterval);
    }
});

// Global error handler
window.addEventListener('error', (event) => {
    console.error('Global error:', event.error);
    dashboard.updateConnectionStatus(false);
});

// Export dashboard object to global scope for debugging
window.dashboard = dashboard;

// Console welcome message
console.log('%c Call Reports Dashboard v2.0.0 ', 'background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 10px; border-radius: 5px; font-weight: bold;');
console.log('Dashboard initialized successfully. Use window.dashboard to access the API.');
