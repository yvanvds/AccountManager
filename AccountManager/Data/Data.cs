using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed class Data
    {
        private static readonly Lazy<Data> data = new Lazy<Data>(() => new Data());

        public static Data Instance { get { return data.Value; } }

        string appFolder;
        const string wisaSchoolsFile = "wisaSchools.json";
        const string wisaClassFile = "wisaClasses.json";
        const string wisaStudentsFile = "wisaStudents.json";

        private Data()
        {
            wisaServer = Properties.Settings.Default.WisaServer;
            wisaPort = Properties.Settings.Default.WisaPort;
            wisaDatabase = Properties.Settings.Default.WisaDatabase;
            wisaUser = Properties.Settings.Default.WisaUser;
            wisaPassword = Properties.Settings.Default.WisaPassword;
            wisaConnectionTested = Properties.Settings.Default.WisaConnectionTested;
            wisaWorkDateNow = Properties.Settings.Default.WisaWorkDateNow;

            // if WisaWorkDateNow is true, the current date is used as 'werkdatum'
            // if not, the saved date will be used
            if(WisaWorkDateNow)
            {
                wisaWorkDate = DateTime.Now;
            } else
            {
                wisaWorkDate = Properties.Settings.Default.WisaWorkDate;
            }

            appFolder = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            appFolder = Path.Combine(appFolder, "AccountManager");
            if(!Directory.Exists(appFolder))
            {
                Directory.CreateDirectory(appFolder);
            }
        }

        public void LoadFileContentOnStartup()
        {
            SetWisaCredentials();

            var wisaSchoolsLocation = Path.Combine(appFolder, wisaSchoolsFile);
            if (File.Exists(wisaSchoolsLocation))
            {
                string content = File.ReadAllText(wisaSchoolsLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                WisaApi.Schools.FromJson(newObj);
            }

            var wisaClassLocation = Path.Combine(appFolder, wisaClassFile);
            if (File.Exists(wisaClassLocation))
            {
                string content = File.ReadAllText(wisaClassLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                WisaApi.ClassGroups.FromJson(newObj);
            }

            var wisaStudentLocation = Path.Combine(appFolder, wisaStudentsFile);
            if (File.Exists(wisaStudentLocation))
            {
                string content = File.ReadAllText(wisaStudentLocation);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                WisaApi.Students.FromJson(newObj);
            }
        }


        #region WISA
        private string wisaServer;

        public string WisaServer
        {
            get { return wisaServer; }
            set {
                wisaServer = value.Trim();
                Properties.Settings.Default.WisaServer = wisaServer;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPort;

        public string WisaPort
        {
            get { return wisaPort; }
            set {
                wisaPort = value.Trim();
                Properties.Settings.Default.WisaPort = wisaPort;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaDatabase;

        public string WisaDatabase
        {
            get { return wisaDatabase; }
            set {
                wisaDatabase = value.Trim();
                Properties.Settings.Default.WisaDatabase = wisaDatabase;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaUser;

        public string WisaUser
        {
            get { return wisaUser; }
            set {
                wisaUser = value.Trim();
                Properties.Settings.Default.WisaUser = wisaUser;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPassword;

        public string WisaPassword
        {
            get { return wisaPassword; }
            set {
                wisaPassword = value.Trim();
                Properties.Settings.Default.WisaPassword = wisaPassword;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private ConfigState wisaConnectionTested;

        public ConfigState WisaConnectionTested
        {
            get { return wisaConnectionTested; }
            set {
                wisaConnectionTested = value;
                Properties.Settings.Default.WisaConnectionTested = wisaConnectionTested;
                Properties.Settings.Default.Save();
            }
        }

        // if this is true, we will use the current date.
        // if not, the saved workdate will be used.
        private bool wisaWorkDateNow;
        public bool WisaWorkDateNow
        {
            get => wisaWorkDateNow;
            set
            {
                wisaWorkDateNow = value;
                Properties.Settings.Default.WisaWorkDateNow = wisaWorkDateNow;
                Properties.Settings.Default.Save();
            }
        }

        private DateTime wisaWorkDate;
        public DateTime WisaWorkDate
        {
            get => wisaWorkDate;
            set
            {
                wisaWorkDate = value;
                Properties.Settings.Default.WisaWorkDate = wisaWorkDate;
                Properties.Settings.Default.Save();
            }
        }

        public void SetWisaCredentials()
        {
            int port = 0;
            try
            {
                port = Convert.ToInt32(WisaPort);
            } catch(Exception)
            {
                MainWindow.Instance.Log.AddError(Origin.Wisa, "Port should be a number");
                return;
            }
            

            WisaApi.Connector.Init(
                WisaServer, port, WisaUser, WisaPassword, WisaDatabase, MainWindow.Instance.Log
            );
        }

        public async Task ReloadWisaSchools()
        {
            // remember which schools are selected
            List<int> selected = new List<int>();
            foreach(var school in WisaApi.Schools.All)
            {
                if (school.IsActive) selected.Add(school.ID);
            }

            // reload list of schools
            bool result = await WisaApi.Schools.Load();

            // only save changes if the request succeeded
            if(result)
            {
                // set to selected if the previous had them selected
                foreach (var school in WisaApi.Schools.All)
                {
                    if (selected.Contains(school.ID))
                    {
                        school.IsActive = true;
                    }
                }
                // save to disk
                saveWisaSchoolsToJSON();
            }
        }

        public async Task ReloadWisaClassgroups()
        {
            // check date
            DateTime workDate = WisaWorkDateNow ? DateTime.Now : WisaWorkDate; 

            // reload list of classes
            WisaApi.ClassGroups.Clear();
            foreach(var school in WisaApi.Schools.All)
            {
                if(school.IsActive)
                {
                    bool success = await WisaApi.ClassGroups.AddSchool(school, workDate);
                    if (!success) return;
                }
            }
            WisaApi.ClassGroups.Sort();
            saveWisaClassGroupsToJSON();
        }

        public async Task ReloadWisaStudents()
        {
            // check date
            DateTime workDate = WisaWorkDateNow ? DateTime.Now : WisaWorkDate;

            // reload list of classes
            WisaApi.Students.Clear();
            foreach (var school in WisaApi.Schools.All)
            {
                if (school.IsActive)
                {
                    bool success = await WisaApi.Students.AddSchool(school, workDate);
                    if (!success) return;
                }
            }
            WisaApi.Students.Sort();
            saveWisaStudentsToJSON();
        }

        public void saveWisaSchoolsToJSON()
        {
            var json = WisaApi.Schools.ToJson();
            var location = Path.Combine(appFolder, wisaSchoolsFile);
            File.WriteAllText(location, json.ToString());
        }

        public void saveWisaClassGroupsToJSON()
        {
            var json = WisaApi.ClassGroups.ToJson();
            var location = Path.Combine(appFolder, wisaClassFile);
            File.WriteAllText(location, json.ToString());
        }

        public void saveWisaStudentsToJSON()
        {
            var json = WisaApi.Students.ToJson();
            var location = Path.Combine(appFolder, wisaStudentsFile);
            File.WriteAllText(location, json.ToString());
        }
        #endregion WISA
    }
}
