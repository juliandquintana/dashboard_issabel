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
    b  background-color: #e9ecef;
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
 ackground: white;
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

    print_success "Archivo dashboard.css completado correctamente"
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
EOF

    print_success "Archivo dashboard.js completo creado exitosamente"
}
# Set proper permissions and security
configure_permissions() {
    print_status "Configurando permisos y seguridad..."
    
    # Set ownership to web server user
    if command -v apache2 &> /dev/null || systemctl is-active --quiet apache2; then
        WEB_USER="www-data"
        WEB_GROUP="www-data"
    elif command -v httpd &> /dev/null || systemctl is-active --quiet httpd; then
        WEB_USER="apache"
        WEB_GROUP="apache"
    else
        WEB_USER="nginx"
        WEB_GROUP="nginx"
    fi
    
    print_status "Configurando ownership para usuario web: $WEB_USER:$WEB_GROUP"
    
    # Set ownership
    chown -R "$WEB_USER:$WEB_GROUP" "$DASHBOARD_DIR"
    
    # Set directory permissions
    find "$DASHBOARD_DIR" -type d -exec chmod 755 {} \;
    
    # Set file permissions
    find "$DASHBOARD_DIR" -type f -exec chmod 644 {} \;
    
    # Set special permissions for writable directories
    chmod -R 777 "$DASHBOARD_DIR"/{data,logs,reports}
    
    # Secure sensitive files
    chmod 600 "$DASHBOARD_DIR/config/database.php"
    
    # Create .htaccess for Apache security
    create_htaccess_security
    
    # Create basic security headers
    create_security_headers
    
    print_success "Permisos configurados correctamente"
}

# Create .htaccess security file
create_htaccess_security() {
    print_status "Creando configuración de seguridad Apache..."
    
    cat > "$DASHBOARD_DIR/.htaccess" << 'EOF'
# Call Reports Dashboard - Security Configuration
# Disable server signature
ServerSignature Off

# Prevent access to sensitive files
<FilesMatch "(\.htaccess|\.htpasswd|\.ini|\.log|\.sql|\.conf|\.bak|\.backup)$">
    Require all denied
</FilesMatch>

# Protect config directory
<Directory "config">
    Require all denied
</Directory>

# Protect logs directory from direct access
<Directory "logs">
    Require all denied
</Directory>

# Enable security headers
<IfModule mod_headers.c>
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
</IfModule>

# Enable compression
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css text/javascript application/javascript application/json
</IfModule>

# Browser caching for static assets
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType text/css "access plus 1 month"
    ExpiresByType application/javascript "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/svg+xml "access plus 1 month"
</IfModule>

# Prevent PHP execution in uploads directory
<Directory "data">
    php_flag engine off
</Directory>

# Rate limiting (if mod_security is available)
<IfModule mod_security.c>
    SecAction "id:1001,phase:1,nolog,pass,initcol:ip=%{REMOTE_ADDR},setvar:ip.requests=+1,expirevar:ip.requests=60"
    SecRule IP:REQUESTS "@gt 60" "id:1002,phase:1,deny,status:429,msg:'Rate limit exceeded'"
</IfModule>
EOF

    print_success "Configuración de seguridad Apache creada"
}

# Create security headers for different web servers
create_security_headers() {
    print_status "Creando archivo de configuración de seguridad..."
    
    cat > "$DASHBOARD_DIR/config/security.php" << 'EOF'
<?php
/**
 * Security Configuration and Headers
 * Applied to all dashboard pages
 */

// Prevent direct access
if (!defined('DASHBOARD_ACCESS')) {
    http_response_code(403);
    exit('Direct access forbidden');
}

// Set security headers
function setSecurityHeaders() {
    // Prevent clickjacking
    header('X-Frame-Options: DENY');
    
    // Prevent MIME type sniffing
    header('X-Content-Type-Options: nosniff');
    
    // Enable XSS protection
    header('X-XSS-Protection: 1; mode=block');
    
    // Referrer policy
    header('Referrer-Policy: strict-origin-when-cross-origin');
    
    // Content Security Policy
    $csp = "default-src 'self'; " .
           "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " .
           "style-src 'self' 'unsafe-inline'; " .
           "img-src 'self' data:; " .
           "font-src 'self'; " .
           "connect-src 'self'; " .
           "frame-ancestors 'none';";
    header("Content-Security-Policy: $csp");
    
    // Remove server information
    header_remove('Server');
    header_remove('X-Powered-By');
    
    // Cache control for API responses
    if (strpos($_SERVER['REQUEST_URI'], '/api/') !== false) {
        header('Cache-Control: no-cache, no-store, must-revalidate');
        header('Pragma: no-cache');
        header('Expires: 0');
    }
}

// Rate limiting function
function checkRateLimit($maxRequests = 60, $timeWindow = 60) {
    $ip = $_SERVER['REMOTE_ADDR'];
    $cacheFile = dirname(__DIR__) . "/data/rate_limit_" . md5($ip) . ".cache";
    
    $currentTime = time();
    $requests = [];
    
    // Load existing requests
    if (file_exists($cacheFile)) {
        $data = file_get_contents($cacheFile);
        $requests = json_decode($data, true) ?: [];
    }
    
    // Clean old requests
    $requests = array_filter($requests, function($timestamp) use ($currentTime, $timeWindow) {
        return ($currentTime - $timestamp) < $timeWindow;
    });
    
    // Check if limit exceeded
    if (count($requests) >= $maxRequests) {
        http_response_code(429);
        header('Retry-After: ' . $timeWindow);
        echo json_encode(['error' => 'Rate limit exceeded']);
        exit;
    }
    
    // Add current request
    $requests[] = $currentTime;
    file_put_contents($cacheFile, json_encode($requests));
}

// Input validation function
function validateInput($input, $type = 'string', $maxLength = 255) {
    if ($input === null || $input === '') {
        return '';
    }
    
    // Remove null bytes
    $input = str_replace("\0", '', $input);
    
    switch ($type) {
        case 'email':
            return filter_var($input, FILTER_VALIDATE_EMAIL) ? $input : '';
        case 'int':
            return filter_var($input, FILTER_VALIDATE_INT) !== false ? (int)$input : 0;
        case 'float':
            return filter_var($input, FILTER_VALIDATE_FLOAT) !== false ? (float)$input : 0.0;
        case 'datetime':
            $date = DateTime::createFromFormat('Y-m-d H:i:s', $input);
            return $date ? $date->format('Y-m-d H:i:s') : '';
        case 'extension':
            // Allow only numeric extensions (3-4 digits)
            return preg_match('/^[0-9]{3,4}$/', $input) ? $input : '';
        default:
            // String validation
            $input = trim($input);
            $input = substr($input, 0, $maxLength);
            return htmlspecialchars($input, ENT_QUOTES, 'UTF-8');
    }
}

// Log security events
function logSecurityEvent($event, $details = []) {
    $logFile = dirname(__DIR__) . '/logs/security.log';
    $logEntry = [
        'timestamp' => date('Y-m-d H:i:s'),
        'ip' => $_SERVER['REMOTE_ADDR'],
        'user_agent' => $_SERVER['HTTP_USER_AGENT'] ?? '',
        'event' => $event,
        'details' => $details
    ];
    
    file_put_contents($logFile, json_encode($logEntry) . "\n", FILE_APPEND | LOCK_EX);
}
?>
EOF

    print_success "Configuración de seguridad creada"
}

# Configure web server specific settings
configure_web_server() {
    print_status "Configurando servidor web..."
    
    # Detect web server
    if systemctl is-active --quiet apache2 || systemctl is-active --quiet httpd; then
        configure_apache_server
    elif systemctl is-active --quiet nginx; then
        configure_nginx_server
    else
        print_warning "Servidor web no detectado automáticamente"
    fi
}

# Configure Apache specific settings
configure_apache_server() {
    print_status "Configurando Apache para el dashboard..."
    
    # Create virtual host configuration (optional)
    if [ "$VHOST_PORT" != "80" ] && [ "$VHOST_PORT" != "443" ]; then
        create_apache_vhost
    fi
    
    # Reload Apache configuration
    if systemctl is-active --quiet apache2; then
        systemctl reload apache2
        print_success "Apache2 recargado"
    elif systemctl is-active --quiet httpd; then
        systemctl reload httpd
        print_success "Apache HTTPD recargado"
    fi
}

# Create Apache virtual host
create_apache_vhost() {
    print_status "Creando virtual host Apache en puerto $VHOST_PORT..."
    
    VHOST_FILE="/etc/apache2/sites-available/callreports-dashboard.conf"
    if [ -d "/etc/httpd/conf.d" ]; then
        VHOST_FILE="/etc/httpd/conf.d/callreports-dashboard.conf"
    fi
    
    cat > "$VHOST_FILE" << EOF
# Call Reports Dashboard Virtual Host
<VirtualHost *:$VHOST_PORT>
    DocumentRoot $DASHBOARD_DIR
    ServerName callreports.local
    
    <Directory $DASHBOARD_DIR>
        AllowOverride All
        Require all granted
        Options -Indexes +FollowSymLinks
        
        # Enable rewrite engine
        RewriteEngine On
        
        # Redirect root to index.html
        RewriteRule ^/?$ /index.html [L,R=301]
    </Directory>
    
    # Security headers
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    Header always set X-XSS-Protection "1; mode=block"
    
    # Logging
    ErrorLog \${APACHE_LOG_DIR}/callreports_error.log
    CustomLog \${APACHE_LOG_DIR}/callreports_access.log combined
</VirtualHost>

# Listen on custom port if not 80
Listen $VHOST_PORT
EOF

    # Enable site if using Apache2
    if command -v a2ensite &> /dev/null; then
        a2ensite callreports-dashboard.conf
        print_status "Virtual host habilitado en Apache2"
    fi
    
    print_success "Virtual host creado: http://localhost:$VHOST_PORT"
}

# Configure Nginx (basic configuration)
configure_nginx_server() {
    print_status "Configurando Nginx para el dashboard..."
    
    NGINX_CONF="/etc/nginx/sites-available/callreports-dashboard"
    
    cat > "$NGINX_CONF" << EOF
# Call Reports Dashboard Nginx Configuration
server {
    listen $VHOST_PORT;
    server_name callreports.local localhost;
    
    root $DASHBOARD_DIR;
    index index.html;
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Main location
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    # API location
    location /api/ {
        try_files \$uri \$uri/ =404;
        
        # PHP processing
        location ~ \.php$ {
            fastcgi_pass unix:/var/run/php/php-fpm.sock;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        }
    }
    
    # Deny access to sensitive files
    location ~ /\.(htaccess|htpasswd|ini|log|sql|conf) {
        deny all;
    }
    
    # Deny access to config directory
    location /config/ {
        deny all;
    }
    
    # Logging
    access_log /var/log/nginx/callreports_access.log;
    error_log /var/log/nginx/callreports_error.log;
}
EOF

    # Enable site
    if [ -d "/etc/nginx/sites-enabled" ]; then
        ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
        systemctl reload nginx
        print_success "Configuración Nginx creada y habilitada"
    fi
}

# Verify installation
verify_installation() {
    print_status "Verificando instalación del dashboard..."
    
    local errors=0
    local warnings=0
    
    # Check directory structure
    print_status "Verificando estructura de directorios..."
    required_dirs=(
        "$DASHBOARD_DIR"
        "$DASHBOARD_DIR/api"
        "$DASHBOARD_DIR/assets/css"
        "$DASHBOARD_DIR/assets/js"
        "$DASHBOARD_DIR/config"
        "$DASHBOARD_DIR/includes"
        "$DASHBOARD_DIR/data"
        "$DASHBOARD_DIR/logs"
        "$DASHBOARD_DIR/reports"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            print_error "Directorio faltante: $dir"
            ((errors++))
        fi
    done
    
    # Check essential files
    print_status "Verificando archivos esenciales..."
    essential_files=(
        "$DASHBOARD_DIR/index.html"
        "$DASHBOARD_DIR/assets/css/dashboard.css"
        "$DASHBOARD_DIR/assets/js/dashboard.js"
        "$DASHBOARD_DIR/config/database.php"
        "$DASHBOARD_DIR/config/settings.php"
        "$DASHBOARD_DIR/includes/Database.class.php"
        "$DASHBOARD_DIR/includes/CallReports.class.php"
        "$DASHBOARD_DIR/api/dashboard-data.php"
        "$DASHBOARD_DIR/api/call-details.php"
        "$DASHBOARD_DIR/api/real-time.php"
        "$DASHBOARD_DIR/api/export.php"
    )
    
    for file in "${essential_files[@]}"; do
        if [ ! -f "$file" ]; then
            print_error "Archivo esencial faltante: $file"
            ((errors++))
        fi
    done
    
    # Check file permissions
    print_status "Verificando permisos..."
    if [ ! -w "$DASHBOARD_DIR/data" ]; then
        print_error "Directorio data no es escribible"
        ((errors++))
    fi
    
    if [ ! -w "$DASHBOARD_DIR/logs" ]; then
        print_error "Directorio logs no es escribible"
        ((errors++))
    fi
    
    # Test database connection
    print_status "Verificando conexión a base de datos..."
    if ! mysql -h"$DB_HOST" -u"$DB_USER_NAME" -p"$DB_USER_PASS" -e "SELECT 1 FROM $CDR_DB.cdr LIMIT 1;" &>/dev/null; then
        print_error "No se puede conectar a la base de datos CDR con el usuario del dashboard"
        ((errors++))
    fi
    
    # Test API endpoints
    print_status "Verificando APIs..."
    if command -v curl &> /dev/null; then
        api_base="http://localhost/$(basename "$DASHBOARD_DIR")/api"
        
        if ! curl -s "$api_base/index.php" | grep -q "dashboard_version"; then
            print_warning "API no responde correctamente (esto puede ser normal si el servidor web no está configurado)"
            ((warnings++))
        fi
    else
        print_warning "curl no disponible, no se pueden probar las APIs"
        ((warnings++))
    fi
    
    # Check web server access
    print_status "Verificando acceso web..."
    if [ ! -r "$DASHBOARD_DIR/index.html" ]; then
        print_error "Archivo index.html no es legible por el servidor web"
        ((errors++))
    fi
    
    # Summary
    echo
    if [ $errors -eq 0 ]; then
        print_success "✅ Verificación de instalación completada exitosamente"
        if [ $warnings -gt 0 ]; then
            print_warning "⚠️  Se encontraron $warnings advertencias (revisables)"
        fi
        return 0
    else
        print_error "❌ Verificación falló con $errors errores y $warnings advertencias"
        return 1
    fi
}

# Create initial log files
create_log_files() {
    print_status "Creando archivos de log iniciales..."
    
    # Create log files with proper permissions
    touch "$DASHBOARD_DIR/logs/error.log"
    touch "$DASHBOARD_DIR/logs/access.log"
    touch "$DASHBOARD_DIR/logs/security.log"
    
    # Set permissions
    chmod 666 "$DASHBOARD_DIR/logs"/*.log
    
    # Create log rotation configuration
    cat > "/etc/logrotate.d/callreports-dashboard" << EOF
$DASHBOARD_DIR/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 666 $WEB_USER $WEB_GROUP
    postrotate
        # Send HUP signal to web server if needed
        /bin/systemctl reload apache2 2>/dev/null || /bin/systemctl reload httpd 2>/dev/null || /bin/systemctl reload nginx 2>/dev/null || true
    endscript
}
EOF

    print_success "Archivos de log configurados"
}

# Test dashboard functionality
test_dashboard_functionality() {
    print_status "Ejecutando pruebas de funcionalidad..."
    
    # Test PHP syntax
    if command -v php &> /dev/null; then
        print_status "Verificando sintaxis PHP..."
        
        php_files=(
            "$DASHBOARD_DIR/config/database.php"
            "$DASHBOARD_DIR/includes/Database.class.php"
            "$DASHBOARD_DIR/includes/CallReports.class.php"
            "$DASHBOARD_DIR/api/dashboard-data.php"
        )
        
        for file in "${php_files[@]}"; do
            if ! php -l "$file" &>/dev/null; then
                print_error "Error de sintaxis en: $file"
                return 1
            fi
        done
        
        print_success "Sintaxis PHP verificada"
    fi
    
    # Test database classes
    print_status "Probando clases de base de datos..."
    
    cat > "/tmp/test_dashboard_db.php" << EOF
<?php
define('DASHBOARD_ACCESS', true);
require_once '$DASHBOARD_DIR/includes/CallReports.class.php';

try {
    \$callReports = new CallReports();
    if (\$callReports->testConnection()) {
        echo "SUCCESS: Database connection working\n";
    } else {
        echo "ERROR: Database connection failed\n";
        exit(1);
    }
} catch (Exception \$e) {
    echo "ERROR: " . \$e->getMessage() . "\n";
    exit(1);
}
?>
EOF

    if php "/tmp/test_dashboard_db.php"; then
        print_success "Clases de base de datos funcionando correctamente"
    else
        print_error "Error en las clases de base de datos"
        return 1
    fi
    
    # Cleanup test file
    rm -f "/tmp/test_dashboard_db.php"
    
    return 0
}
# Rollback function for error recovery
rollback_installation() {
    print_warning "Ejecutando rollback de la instalación..."
    
    # Stop any timers or processes
    local rollback_errors=0
    
    # Remove dashboard directory
    if [ -d "$DASHBOARD_DIR" ]; then
        print_status "Removiendo directorio del dashboard..."
        rm -rf "$DASHBOARD_DIR"
        if [ $? -eq 0 ]; then
            print_status "Directorio del dashboard removido"
        else
            print_error "Error removiendo directorio del dashboard"
            ((rollback_errors++))
        fi
    fi
    
    # Remove database user
    if [ -n "$DB_USER_NAME" ] && [ -n "$DB_ROOT_USER" ] && [ -n "$DB_ROOT_PASS" ]; then
        print_status "Removiendo usuario de base de datos..."
        mysql -h"$DB_HOST" -u"$DB_ROOT_USER" -p"$DB_ROOT_PASS" << SQLEOF 2>/dev/null
DROP USER IF EXISTS '${DB_USER_NAME}'@'localhost';
DROP USER IF EXISTS '${DB_USER_NAME}'@'%';
FLUSH PRIVILEGES;
SQLEOF
        if [ $? -eq 0 ]; then
            print_status "Usuario de base de datos removido"
        else
            print_warning "No se pudo remover el usuario de base de datos"
            ((rollback_errors++))
        fi
    fi
    
    # Remove virtual host configurations
    if [ -f "/etc/apache2/sites-available/callreports-dashboard.conf" ]; then
        a2dissite callreports-dashboard.conf 2>/dev/null
        rm -f "/etc/apache2/sites-available/callreports-dashboard.conf"
        systemctl reload apache2 2>/dev/null
        print_status "Configuración Apache removida"
    fi
    
    if [ -f "/etc/httpd/conf.d/callreports-dashboard.conf" ]; then
        rm -f "/etc/httpd/conf.d/callreports-dashboard.conf"
        systemctl reload httpd 2>/dev/null
        print_status "Configuración HTTPD removida"
    fi
    
    if [ -f "/etc/nginx/sites-available/callreports-dashboard" ]; then
        rm -f "/etc/nginx/sites-enabled/callreports-dashboard"
        rm -f "/etc/nginx/sites-available/callreports-dashboard"
        systemctl reload nginx 2>/dev/null
        print_status "Configuración Nginx removida"
    fi
    
    # Remove log rotation
    if [ -f "/etc/logrotate.d/callreports-dashboard" ]; then
        rm -f "/etc/logrotate.d/callreports-dashboard"
        print_status "Configuración de log rotation removida"
    fi
    
    # Restore backup if available
    if [ -d "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/$(basename "$DASHBOARD_DIR")" ]; then
        print_status "Restaurando respaldo anterior..."
        cp -r "$BACKUP_DIR/$(basename "$DASHBOARD_DIR")" "$(dirname "$DASHBOARD_DIR")/"
        print_status "Respaldo anterior restaurado"
    fi
    
    if [ $rollback_errors -eq 0 ]; then
        print_success "Rollback completado exitosamente"
    else
        print_warning "Rollback completado con $rollback_errors errores menores"
    fi
}

# Uninstall function
uninstall_dashboard() {
    print_status "Desinstalando Call Reports Dashboard..."
    
    # Confirm uninstallation
    echo -e "${YELLOW}¿Está seguro de que desea desinstalar completamente el dashboard? (y/N)${NC}"
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Desinstalación cancelada"
        return 0
    fi
    
    # Use rollback function to clean everything
    rollback_installation
    
    print_success "Call Reports Dashboard desinstalado completamente"
}

# Cleanup function
cleanup_installation() {
    print_status "Ejecutando limpieza post-instalación..."
    
    # Remove temporary files
    rm -f "/tmp/test_dashboard_db.php"
    rm -f "/tmp/callreports_db_config"
    
    # Clean up any test database connections
    pkill -f "mysql.*$DB_USER_NAME" 2>/dev/null || true
    
    # Set final permissions
    if [ -d "$DASHBOARD_DIR" ]; then
        # Ensure logs directory is writable
        chmod 777 "$DASHBOARD_DIR/logs" 2>/dev/null
        chmod 666 "$DASHBOARD_DIR/logs"/*.log 2>/dev/null
        
        # Ensure data directory is writable
        chmod 777 "$DASHBOARD_DIR/data" 2>/dev/null
        
        # Secure config files
        chmod 600 "$DASHBOARD_DIR/config/database.php" 2>/dev/null
    fi
    
    print_success "Limpieza completada"
}

# Display post-installation information
show_installation_summary() {
    echo
    echo -e "${GREEN}
╔══════════════════════════════════════════════════════════════════╗
║                    ¡Instalación Completada!                     ║
║              Call Reports Dashboard v2.0.0 Standalone           ║
╚══════════════════════════════════════════════════════════════════╝
${NC}"
    
    print_success "Dashboard instalado exitosamente como aplicación independiente"
    echo
    echo "📍 UBICACIÓN DEL DASHBOARD:"
    echo "   Directorio: $DASHBOARD_DIR"
    echo "   URL Principal: http://$(hostname -I | awk '{print $1}')/$(basename "$DASHBOARD_DIR")/"
    if [ "$VHOST_PORT" != "80" ]; then
        echo "   URL Alternativa: http://$(hostname -I | awk '{print $1}'):$VHOST_PORT/"
    fi
    echo
    echo "🔗 ACCESO DIRECTO:"
    echo "   • Dashboard: http://localhost/$(basename "$DASHBOARD_DIR")/"
    echo "   • API Documentation: http://localhost/$(basename "$DASHBOARD_DIR")/api/"
    echo "   • Real-time Data: http://localhost/$(basename "$DASHBOARD_DIR")/api/real-time.php"
    echo
    echo "🔧 CONFIGURACIÓN:"
    echo "   • Base de datos: $CDR_DB en $DB_HOST"
    echo "   • Usuario BD: $DB_USER_NAME (solo lectura)"
    echo "   • Logs: $DASHBOARD_DIR/logs/"
    echo "   • Configuración: $DASHBOARD_DIR/config/"
    echo
    echo "📊 CARACTERÍSTICAS:"
    echo "   ✅ Dashboard interactivo con gráficas Chart.js"
    echo "   ✅ APIs REST para integración"
    echo "   ✅ Exportación CSV/JSON"
    echo "   ✅ Filtros avanzados por fecha y extensión"
    echo "   ✅ Monitoreo en tiempo real"
    echo "   ✅ Responsive design para móviles"
    echo "   ✅ Configuración de seguridad incluida"
    echo
    echo "🛠️  COMANDOS ÚTILES:"
    echo "   • Verificar instalación: $0 verify"
    echo "   • Desinstalar: $0 uninstall"
    echo "   • Ver logs: tail -f $DASHBOARD_DIR/logs/error.log"
    echo "   • Reiniciar servidor web: systemctl reload apache2"
    echo
    echo "📁 ARCHIVOS IMPORTANTES:"
    echo "   • Configuración BD: $DASHBOARD_DIR/config/database.php"
    echo "   • Configuración general: $DASHBOARD_DIR/config/settings.php"
    echo "   • Log de instalación: $LOG_FILE"
    if [ -d "$BACKUP_DIR" ]; then
        echo "   • Respaldo: $BACKUP_DIR"
    fi
    echo
    echo "🔐 SEGURIDAD:"
    echo "   ✅ Usuario de BD con permisos limitados (solo SELECT)"
    echo "   ✅ Validación de entrada y headers de seguridad"
    echo "   ✅ Rate limiting básico incluido"
    echo "   ✅ Archivos sensibles protegidos con .htaccess"
    echo
    echo "🚀 PRÓXIMOS PASOS:"
    echo "   1. Abrir el dashboard en su navegador"
    echo "   2. Verificar que los datos CDR se muestren correctamente"
    echo "   3. Configurar filtros según sus necesidades"
    echo "   4. Probar la funcionalidad de exportación"
    echo
    echo -e "${YELLOW}💡 NOTA: Este dashboard es independiente de Issabel PBX y no"
    echo -e "   interfiere con su funcionamiento normal.${NC}"
    echo
    if [ "$VHOST_PORT" != "80" ]; then
        echo -e "${BLUE}🌐 Para acceso externo, abra el puerto $VHOST_PORT en su firewall:${NC}"
        echo "   firewall-cmd --permanent --add-port=$VHOST_PORT/tcp"
        echo "   firewall-cmd --reload"
        echo
    fi
}

# Handle errors and setup trap
handle_error() {
    local exit_code=$?
    print_error "Error detectado en la línea $1. Código de salida: $exit_code"
    
    if [ -n "$DASHBOARD_DIR" ] && [ -d "$DASHBOARD_DIR" ]; then
        echo -e "${YELLOW}¿Desea ejecutar rollback automático? (y/N)${NC}"
        read -t 10 -r rollback_choice
        
        if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
            rollback_installation
        fi
    fi
    
    exit $exit_code
}

# Set error trap
trap 'handle_error $LINENO' ERR

# Main installation function
main_install() {
    print_header
    
    log "Iniciando instalación de Call Reports Dashboard v2.0.0 Standalone"
    
    # Pre-installation checks
    check_root
    check_requirements
    
    # Database configuration
    get_database_config
    create_database_user
    
    # Create dashboard structure
    create_dashboard_structure
    
    # Create configuration files
    create_database_config
    create_settings_config
    
    # Create PHP classes
    create_database_class
    create_callreports_class
    
    # Create APIs
    create_dashboard_data_api
    create_call_details_api
    create_realtime_api
    create_export_api
    create_api_index
    
    # Create frontend
    create_main_html
    create_css_stylesheet
    create_javascript_file
    
    # Configuration and security
    configure_permissions
    configure_web_server
    create_log_files
    
    # Testing and verification
    if test_dashboard_functionality; then
        print_success "Pruebas de funcionalidad completadas"
    else
        print_error "Falló las pruebas de funcionalidad"
        exit 1
    fi
    
    if verify_installation; then
        print_success "Verificación de instalación exitosa"
    else
        print_error "Falló la verificación de instalación"
        exit 1
    fi
    
    # Cleanup and finalization
    cleanup_installation
    
    # Show installation summary
    show_installation_summary
    
    log "Instalación completada exitosamente"
}

# Show usage information
show_usage() {
    echo "Call Reports Dashboard v2.0.0 - Instalador Standalone"
    echo
    echo "Uso: $0 [comando] [opciones]"
    echo
    echo "Comandos disponibles:"
    echo "  install     Instalar el dashboard (por defecto)"
    echo "  uninstall   Desinstalar completamente el dashboard"
    echo "  verify      Verificar instalación existente"
    echo "  rollback    Ejecutar rollback manual"
    echo "  --help, -h  Mostrar esta ayuda"
    echo
    echo "Opciones:"
    echo "  --port=PORT     Puerto para virtual host (default: 8081)"
    echo "  --dir=DIR       Directorio de instalación personalizado"
    echo "  --no-vhost      No crear virtual host"
    echo
    echo "Ejemplos:"
    echo "  $0 install                    # Instalación estándar"
    echo "  $0 install --port=8080        # Instalar en puerto 8080"
    echo "  $0 verify                     # Verificar instalación"
    echo "  $0 uninstall                  # Desinstalar completamente"
    echo
    echo "El dashboard se instalará como aplicación web independiente que"
    echo "NO interfiere con Issabel PBX y solo requiere acceso de lectura"
    echo "a la base de datos CDR."
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port=*)
                VHOST_PORT="${1#*=}"
                shift
                ;;
            --dir=*)
                CUSTOM_DIR="${1#*=}"
                DASHBOARD_DIR="$CUSTOM_DIR"
                shift
                ;;
            --no-vhost)
                VHOST_PORT="80"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                # Unknown option
                print_error "Opción desconocida: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution logic
case "${1:-install}" in
    "install")
        shift
        parse_arguments "$@"
        main_install
        ;;
    "uninstall")
        check_root
        uninstall_dashboard
        ;;
    "verify")
        if [ -d "$DASHBOARD_DIR" ]; then
            verify_installation
        else
            print_error "Dashboard no está instalado en $DASHBOARD_DIR"
            exit 1
        fi
        ;;
    "rollback")
        check_root
        rollback_installation
        ;;
    "--help"|"-h")
        show_usage
        exit 0
        ;;
    *)
        print_error "Comando desconocido: $1"
        show_usage
        exit 1
        ;;
esac

exit 0
# Create additional utility functions
create_utility_functions() {
    print_status "Creando funciones utilitarias adicionales..."
    
    # Create maintenance script
    cat > "$DASHBOARD_DIR/maintenance.php" << 'EOF'
<?php
/**
 * Call Reports Dashboard - Maintenance Script
 * Run this script periodically to maintain optimal performance
 */

define('DASHBOARD_ACCESS', true);
require_once 'includes/Database.class.php';

class DashboardMaintenance {
    private $db;
    
    public function __construct() {
        $this->db = Database::getInstance();
    }
    
    public function runMaintenance() {
        echo "Starting Call Reports Dashboard maintenance...\n";
        
        $this->cleanupOldLogs();
        $this->cleanupCacheFiles();
        $this->optimizeDatabase();
        $this->generateHealthReport();
        
        echo "Maintenance completed successfully.\n";
    }
    
    private function cleanupOldLogs() {
        echo "Cleaning up old log files...\n";
        
        $logDir = __DIR__ . '/logs/';
        $files = glob($logDir . '*.log');
        $cutoffTime = time() - (30 * 24 * 60 * 60); // 30 days
        
        foreach ($files as $file) {
            if (filemtime($file) < $cutoffTime && filesize($file) > 10 * 1024 * 1024) { // 10MB
                $backup = $file . '.old.' . date('Y-m-d');
                rename($file, $backup);
                touch($file);
                echo "Archived large log file: " . basename($file) . "\n";
            }
        }
    }
    
    private function cleanupCacheFiles() {
        echo "Cleaning up cache files...\n";
        
        $dataDir = __DIR__ . '/data/';
        $files = glob($dataDir . 'rate_limit_*.cache');
        $cutoffTime = time() - (24 * 60 * 60); // 24 hours
        
        foreach ($files as $file) {
            if (filemtime($file) < $cutoffTime) {
                unlink($file);
            }
        }
        
        echo "Cache cleanup completed.\n";
    }
    
    private function optimizeDatabase() {
        echo "Checking database optimization...\n";
        
        // This is a read-only user, so we can't optimize tables
        // But we can check connection and table status
        try {
            $result = $this->db->fetchRow("SELECT COUNT(*) as count FROM cdr LIMIT 1");
            echo "Database connection: OK\n";
            echo "CDR table accessible: " . ($result ? "YES" : "NO") . "\n";
        } catch (Exception $e) {
            echo "Database error: " . $e->getMessage() . "\n";
        }
    }
    
    private function generateHealthReport() {
        echo "Generating health report...\n";
        
        $report = [
            'timestamp' => date('Y-m-d H:i:s'),
            'disk_usage' => $this->getDiskUsage(),
            'memory_usage' => memory_get_peak_usage(true),
            'php_version' => PHP_VERSION,
            'database_status' => $this->db->isConnected() ? 'OK' : 'ERROR'
        ];
        
        file_put_contents(__DIR__ . '/logs/health_report.json', json_encode($report, JSON_PRETTY_PRINT));
        echo "Health report saved to logs/health_report.json\n";
    }
    
    private function getDiskUsage() {
        $bytes = disk_total_space(__DIR__) - disk_free_space(__DIR__);
        return round($bytes / 1024 / 1024, 2) . ' MB';
    }
}

// Run maintenance if called directly
if (php_sapi_name() === 'cli') {
    $maintenance = new DashboardMaintenance();
    $maintenance->runMaintenance();
}
?>
EOF

    # Create update script
    cat > "$DASHBOARD_DIR/update.sh" << 'EOF'
#!/bin/bash
# Call Reports Dashboard - Update Script

DASHBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/tmp/callreports_update_backup_$(date +%Y%m%d_%H%M%S)"

echo "Call Reports Dashboard Update Script"
echo "======================================"

# Create backup
echo "Creating backup..."
mkdir -p "$BACKUP_DIR"
cp -r "$DASHBOARD_DIR" "$BACKUP_DIR/"
echo "Backup created: $BACKUP_DIR"

# Clear cache
echo "Clearing cache..."
rm -f "$DASHBOARD_DIR/data/rate_limit_*.cache"

# Run maintenance
echo "Running maintenance..."
php "$DASHBOARD_DIR/maintenance.php"

# Check file permissions
echo "Checking permissions..."
chmod -R 755 "$DASHBOARD_DIR"
chmod -R 777 "$DASHBOARD_DIR/data" "$DASHBOARD_DIR/logs"
chmod 600 "$DASHBOARD_DIR/config/database.php"

echo "Update completed successfully!"
echo "Backup available at: $BACKUP_DIR"
EOF

    chmod +x "$DASHBOARD_DIR/update.sh"
    
    print_success "Funciones utilitarias creadas"
}

# Create documentation
create_documentation() {
    print_status "Creando documentación..."
    
    cat > "$DASHBOARD_DIR/README.md" << 'EOF'
# Call Reports Dashboard v2.0.0

## Descripción
Dashboard independiente para análisis de llamadas de Asterisk/Issabel. Proporciona visualizaciones interactivas, reportes detallados y APIs REST sin interferir con el sistema PBX.

## Características
- 📊 Gráficas interactivas con Chart.js
- 🔍 Filtros avanzados por fecha y extensión
- 📱 Diseño responsive para móviles
- 🔄 Monitoreo en tiempo real
- 📤 Exportación CSV/JSON
- 🔒 Configuración de seguridad incluida
- 🚀 APIs REST para integración

## Estructura de Archivos
```
callreports/
├── index.html              # Dashboard principal
├── api/                    # APIs REST
│   ├── dashboard-data.php  # Datos del dashboard
│   ├── call-details.php    # Detalles de llamadas
│   ├── real-time.php       # Datos en tiempo real
│   └── export.php          # Exportación de datos
├── assets/                 # Recursos estáticos
│   ├── css/dashboard.css   # Estilos
│   └── js/dashboard.js     # JavaScript principal
├── config/                 # Configuración
│   ├── database.php        # Configuración de BD
│   └── settings.php        # Configuración general
├── includes/               # Clases PHP
│   ├── Database.class.php  # Conexión a BD
│   └── CallReports.class.php # Lógica de reportes
├── data/                   # Datos temporales
├── logs/                   # Archivos de log
└── maintenance.php         # Script de mantenimiento
```

## APIs Disponibles

### GET /api/dashboard-data.php
Obtiene datos principales del dashboard
- Parámetros: date_start, date_end, extension
- Respuesta: JSON con métricas, gráficas y tablas

### GET /api/call-details.php
Obtiene detalles de llamadas con paginación
- Parámetros: date_start, date_end, extension, limit, offset
- Respuesta: JSON con array de llamadas

### GET /api/real-time.php
Obtiene datos en tiempo real del sistema
- Respuesta: JSON con estado del sistema y actividad reciente

### POST /api/export.php
Exporta datos en formato CSV o JSON
- Parámetros: date_start, date_end, extension, format, max_records
- Respuesta: Archivo descargable

## Mantenimiento

### Mantenimiento Automático
```bash
# Ejecutar script de mantenimiento
php maintenance.php

# Actualizar permisos y limpiar cache
./update.sh
```

### Logs
- `logs/error.log` - Errores de PHP
- `logs/access.log` - Accesos al dashboard
- `logs/security.log` - Eventos de seguridad
- `logs/health_report.json` - Reporte de estado

### Seguridad
- Usuario de BD con permisos limitados (solo SELECT)
- Validación de entrada en todas las APIs
- Headers de seguridad configurados
- Rate limiting básico incluido
- Archivos sensibles protegidos

## Troubleshooting

### Dashboard no carga
1. Verificar permisos de archivos
2. Revisar logs de error del servidor web
3. Comprobar conexión a base de datos

### APIs no responden
1. Verificar configuración PHP
2. Revisar logs/error.log
3. Comprobar usuario de base de datos

### Gráficas no se muestran
1. Verificar conexión a internet (Chart.js CDN)
2. Revisar consola del navegador
3. Comprobar datos en las APIs

## Información Técnica
- Versión: 2.0.0
- Compatibilidad: PHP 7.4+, MySQL 5.7+
- Dependencias: Chart.js (CDN)
- Licencia: GPL v3
EOF

    # Create API documentation
    cat > "$DASHBOARD_DIR/API_DOCUMENTATION.md" << 'EOF'
# API Documentation - Call Reports Dashboard

## Base URL
```
http://your-server/callreports/api/
```

## Authentication
Currently no authentication is required. APIs use rate limiting for basic protection.

## Rate Limiting
- 60 requests per minute per IP address
- 429 status code when limit exceeded

## Error Responses
All APIs return errors in this format:
```json
{
    "status": "error",
    "message": "Error description",
    "timestamp": 1643723400
}
```

## Success Responses
All APIs return success responses with:
```json
{
    "status": "success",
    "timestamp": 1643723400,
    "data": { ... }
}
```

## Endpoints

### 1. Dashboard Data API
**GET** `/dashboard-data.php`

Returns comprehensive dashboard statistics including call summary, trends, and distributions.

**Parameters:**
- `date_start` (string): Start date in 'Y-m-d H:i:s' format
- `date_end` (string): End date in 'Y-m-d H:i:s' format  
- `extension` (string, optional): Filter by specific extension

**Example Request:**
```
GET /api/dashboard-data.php?date_start=2025-01-01%2000:00:00&date_end=2025-01-31%2023:59:59&extension=1001
```

**Example Response:**
```json
{
    "status": "success",
    "timestamp": 1643723400,
    "call_summary": {
        "total_calls": 1250,
        "answered_calls": 1100,
        "answer_rate": 88.0,
        "avg_duration_formatted": "00:03:45"
    },
    "daily_trends": [...],
    "hourly_distribution": [...],
    "extension_stats": [...],
    "top_destinations": [...]
}
```

### 2. Call Details API
**GET** `/call-details.php`

Returns detailed call records with pagination support.

**Parameters:**
- `date_start` (string): Start date
- `date_end` (string): End date
- `extension` (string, optional): Filter by extension
- `limit` (int): Records per page (1-1000, default: 100)
- `offset` (int): Pagination offset (default: 0)
- `include_total` (bool): Include total count (expensive query)

**Example Request:**
```
GET /api/call-details.php?date_start=2025-01-01%2000:00:00&limit=50&offset=0
```

### 3. Real-time Data API
**GET** `/real-time.php`

Returns current system status and recent activity.

**No Parameters Required**

**Example Response:**
```json
{
    "status": "success",
    "timestamp": 1643723400,
    "system_status": {
        "database_status": "connected",
        "last_call_time": "2025-01-15 14:30:25"
    },
    "recent_activity": {
        "total_calls": 45,
        "answered_calls": 38
    }
}
```

### 4. Export API
**POST** `/export.php`

Exports call data in CSV or JSON format.

**Parameters:**
- `date_start` (string): Start date
- `date_end` (string): End date
- `extension` (string, optional): Filter by extension
- `format` (string): Export format ('csv' or 'json')
- `max_records` (int): Maximum records (1-10000, default: 5000)

**Example Request:**
```bash
curl -X POST http://your-server/callreports/api/export.php \
  -d "date_start=2025-01-01 00:00:00" \
  -d "date_end=2025-01-31 23:59:59" \
  -d "format=csv" \
  -d "max_records=1000"
```

## JavaScript SDK
The dashboard includes a JavaScript object for easy API access:

```javascript
// Get dashboard data
dashboard.apiRequest('dashboard-data.php?date_start=2025-01-01 00:00:00&date_end=2025-01-31 23:59:59')
  .then(data => console.log(data));

// Get call details
dashboard.apiRequest('call-details.php?limit=100')
  .then(data => console.log(data));
```

## HTTP Status Codes
- `200` - Success
- `400` - Bad Request (invalid parameters)
- `429` - Too Many Requests (rate limit exceeded)
- `500` - Internal Server Error
EOF

    print_success "Documentación creada"
}

# Create final security checks
final_security_check() {
    print_status "Ejecutando verificaciones finales de seguridad..."
    
    # Check file permissions
    local security_issues=0
    
    # Database config should not be world readable
    if [ -f "$DASHBOARD_DIR/config/database.php" ]; then
        local perms=$(stat -c %a "$DASHBOARD_DIR/config/database.php" 2>/dev/null || stat -f %A "$DASHBOARD_DIR/config/database.php" 2>/dev/null)
        if [ "$perms" != "600" ]; then
            print_warning "Archivo database.php no tiene permisos seguros (600)"
            chmod 600 "$DASHBOARD_DIR/config/database.php"
            ((security_issues++))
        fi
    fi
    
    # Check for sensitive files in web root
    sensitive_patterns=("*.sql" "*.bak" "*.backup" "*.conf" "*.ini")
    for pattern in "${sensitive_patterns[@]}"; do
        if find "$DASHBOARD_DIR" -name "$pattern" -type f 2>/dev/null | grep -q .; then
            print_warning "Archivos sensibles encontrados con patrón: $pattern"
            ((security_issues++))
        fi
    done
    
    # Test database user permissions
    if mysql -h"$DB_HOST" -u"$DB_USER_NAME" -p"$DB_USER_PASS" -e "CREATE TABLE test_table (id INT);" "$CDR_DB" &>/dev/null; then
        print_error "Usuario de BD tiene permisos de escritura (RIESGO DE SEGURIDAD)"
        mysql -h"$DB_HOST" -u"$DB_USER_NAME" -p"$DB_USER_PASS" -e "DROP TABLE test_table;" "$CDR_DB" &>/dev/null
        ((security_issues++))
    else
        print_success "Usuario de BD tiene permisos limitados correctamente"
    fi
    
    if [ $security_issues -eq 0 ]; then
        print_success "Verificación de seguridad completada sin problemas"
    else
        print_warning "Se encontraron $security_issues problemas de seguridad menores"
    fi
}

# Create version and license information
create_version_info() {
    print_status "Creando información de versión y licencia..."
    
    cat > "$DASHBOARD_DIR/VERSION" << 'EOF'
Call Reports Dashboard
Version: 2.0.0 Standalone
Build Date: 2025-01-15
PHP Minimum: 7.4
MySQL Minimum: 5.7
License: GPL v3

Features:
- Interactive dashboards with Chart.js
- REST APIs for integration
- Real-time monitoring
- CSV/JSON export
- Responsive design
- Security headers and rate limiting
- Independent from Issabel PBX modules

Compatibility:
- Issabel 4.x
- FreePBX 15+
- Asterisk 11.25.3+
- Apache 2.4+
- Nginx 1.14+
- PHP 7.4+
- MySQL 5.7+ / MariaDB 10.3+
EOF

    cat > "$DASHBOARD_DIR/LICENSE" << 'EOF'
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2025 Call Reports Dashboard

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Additional Terms:
- This software is designed to work with Asterisk PBX systems
- No warranty is provided for data accuracy or system performance
- Users are responsible for backup and security of their data
- Commercial support may be available separately
EOF

    print_success "Información de versión y licencia creada"
}

# Final cleanup and optimization
final_cleanup() {
    print_status "Ejecutando limpieza final..."
    
    # Remove any temporary files
    find "$DASHBOARD_DIR" -name "*.tmp" -delete 2>/dev/null || true
    find "$DASHBOARD_DIR" -name ".DS_Store" -delete 2>/dev/null || true
    find "$DASHBOARD_DIR" -name "Thumbs.db" -delete 2>/dev/null || true
    
    # Ensure all log files exist
    touch "$DASHBOARD_DIR/logs/error.log"
    touch "$DASHBOARD_DIR/logs/access.log" 
    touch "$DASHBOARD_DIR/logs/security.log"
    
    # Set final ownership
    if command -v apache2 &> /dev/null || systemctl is-active --quiet apache2; then
        chown -R www-data:www-data "$DASHBOARD_DIR" 2>/dev/null || true
    elif command -v httpd &> /dev/null || systemctl is-active --quiet httpd; then
        chown -R apache:apache "$DASHBOARD_DIR" 2>/dev/null || true
    fi
    
    # Create symlink for easy access (optional)
    if [ ! -L "/var/www/html/dashboard" ] && [ "$DASHBOARD_DIR" != "/var/www/html/dashboard" ]; then
        ln -sf "$DASHBOARD_DIR" "/var/www/html/dashboard" 2>/dev/null || true
    fi
    
    print_success "Limpieza final completada"
}

# Complete the main install function by adding the new functions
complete_main_install() {
    # Add these calls to main_install function before show_installation_summary
    create_utility_functions
    create_documentation
    final_security_check
    create_version_info
    final_cleanup
}

# Initialize environment
init_environment() {
    # Set locale
    export LC_ALL=C
    
    # Set umask for secure file creation
    umask 022
    
    # Create lock file to prevent multiple instances
    LOCK_FILE="/tmp/callreports_install.lock"
    
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            print_error "Otra instancia del instalador está ejecutándose (PID: $lock_pid)"
            exit 1
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    
    # Cleanup lock file on exit
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# Script initialization
init_environment

# Add the complete functions to main install
main_install() {
    print_header
    
    log "Iniciando instalación de Call Reports Dashboard v2.0.0 Standalone"
    
    # Pre-installation checks
    check_root
    check_requirements
    
    # Database configuration
    get_database_config
    create_database_user
    
    # Create dashboard structure
    create_dashboard_structure
    
    # Create configuration files
    create_database_config
    create_settings_config
    
    # Create PHP classes
    create_database_class
    create_callreports_class
    
    # Create APIs
    create_dashboard_data_api
    create_call_details_api
    create_realtime_api
    create_export_api
    create_api_index
    
    # Create frontend
    create_main_html
    create_css_stylesheet
    create_javascript_file
    
    # Configuration and security
    configure_permissions
    configure_web_server
    create_log_files
    
    # Additional functions
    create_utility_functions
    create_documentation
    
    # Testing and verification
    if test_dashboard_functionality; then
        print_success "Pruebas de funcionalidad completadas"
    else
        print_error "Falló las pruebas de funcionalidad"
        exit 1
    fi
    
    if verify_installation; then
        print_success "Verificación de instalación exitosa"
    else
        print_error "Falló la verificación de instalación"
        exit 1
    fi
    
    # Final steps
    final_security_check
    create_version_info
    cleanup_installation
    final_cleanup
    
    # Show installation summary
    show_installation_summary
    
    log "Instalación completada exitosamente"
}

# End of script marker
print_status "Script del instalador Call Reports Dashboard v2.0.0 Standalone completado"
print_status "Uso: ./install_callreports_standalone.sh [install|uninstall|verify|rollback]"
print_status "Para más información: ./install_callreports_standalone.sh --help"
