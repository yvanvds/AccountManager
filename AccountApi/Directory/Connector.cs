using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    static public class Connector
    {
        private static readonly string root = "LDAP://";
        internal static string Root { get => root; }

        private static string domainPath;

        public static string AzureDomain;

        private static string accountPath;
        internal static string AccountPath { get => accountPath; }

        private static string groupPath;
        internal static string GroupPath { get => groupPath; }

        private static string studentPath;
        internal static string StudentPath { get => studentPath; }

        private static string staffPath;
        internal static string StaffPath { get => staffPath; }

        public static string TeacherOU;
        public static string SupportOU;
        public static string DirectorOU;
        public static string AdminOU;
        public static string OtherOU;

        public static string[] StudentGrade;
        public static string[] StudentYear;

        internal static ILog Log;

        private static DirectoryEntry connection;

        public static bool Init(string domain, string accounts, string groups, string students, string staff, ILog log = null)
        {
            Log = log;

            domainPath = domain;
            accountPath = accounts;
            groupPath = groups;
            studentPath = students;
            staffPath = staff;

            try
            {
                connection = new DirectoryEntry(Root + domainPath)
                {
                    AuthenticationType = AuthenticationTypes.Secure
                };
            }
            catch (DirectoryServicesCOMException e)
            {
                Log.AddError(Origin.Directory, e.Message);
                return false;
            }
            catch (Exception e)
            {
                Log.AddError(Origin.Directory, e.Message);
                return false;
            }

            return true;
        }

        public static void Close()
        {
            connection?.Close();
        }

        public static DirectorySearcher GetSearcher(string path)
        {
            if (!path.StartsWith(Root))
            {
                path = Root + path;
            }
            connection.Path = path;
            return new DirectorySearcher(connection);
        }

        public static string CreateNewID(string firstname, string lastname)
        {
            firstname = firstname.Trim().ToLower();
            lastname = lastname.Trim().ToLower();

            Regex rgx = new Regex("[^a-zA-Z]");
            firstname = rgx.Replace(firstname, "");
            lastname = rgx.Replace(lastname, "");

            int pos = 0;
            if (lastname.StartsWith("de")) pos = 2;
            if (lastname.StartsWith("ver")) pos = 3;
            if (lastname.StartsWith("van")) pos = 3;
            if (lastname.StartsWith("vande")) pos = 5;
            if (lastname.StartsWith("vander")) pos = 6;

            int length = lastname.Length - pos;
            if (length > 5) length = 5;

            string id = lastname.Substring(pos, length);
            id += firstname[0];

            int counter = 0;

            string test_id = id;

            while (true)
            {
                if (!AccountManager.Exists(test_id))
                {
                    return test_id;
                }
                else
                {
                    counter++;
                    test_id = id + counter;
                }
            }
        }

        public static string CreateNewAlias(string firstname, string lastname)
        {
            firstname = firstname.Trim().ToLower();
            lastname = lastname.Trim().ToLower();

            Regex rgx = new Regex("[^a-zA-Z]");
            firstname = rgx.Replace(firstname, "");
            lastname = rgx.Replace(lastname, "");

            string mail = firstname;
            mail += "."; mail += lastname;
            mail += "@sanctamaria-aarschot.be";

            int counter = 0;

            while (AccountManager.HasAlias(mail))
            {
                counter++;
                mail = firstname;
                mail += "."; mail += lastname; mail += counter;
                mail += "@sanctamaria-aarschot.be";
            }

            return mail;
        }

        public static void CreateOUIfneeded(string path)
        {
            string[] ou;
            ou = path.Split(',');
            if (ou[0].StartsWith("LDAP://"))
            {
                ou[0] = ou[0].Substring(7);
            }

            // remove empty parts
            ou = ou.Where(x => !string.IsNullOrEmpty(x)).ToArray();

            if (ou.Length < 5) return;

            string parent = ou[ou.Length - 3] + "," + ou[ou.Length - 2] + "," + ou[ou.Length - 1];


            for (int i = ou.Length - 4; i >= 0; i--)
            {


                if (ou[i].Substring(0, 2).Equals("OU", StringComparison.CurrentCultureIgnoreCase))
                {
                    if (!DirectoryEntry.Exists(Root + ou[i] + "," + parent))
                    {
                        DirectoryEntry ouEntry = new DirectoryEntry(Root + parent);
                        DirectoryEntry child = ouEntry.Children.Add(ou[i], "OrganizationalUnit");
                        child.CommitChanges();
                        ouEntry.CommitChanges();
                        Log.AddMessage(Origin.Directory, "Created Unit: " + ou[i]);
                    }
                }

                parent = ou[i] + "," + parent;
            }
        }

        public static string GetPath(AccountRole role, string classgroup = "")
        {
            switch (role)
            {
                case AccountRole.Director:
                    return "OU=" + DirectorOU + "," + StaffPath;
                case AccountRole.IT:
                    return "OU=" + AdminOU + "," + StaffPath;
                case AccountRole.Support:
                    return "OU=" + SupportOU + "," + StaffPath;
                case AccountRole.Teacher:
                    return "OU=" + TeacherOU + "," + StaffPath;
                case AccountRole.Student:
                    return GetStudentpath(classgroup);
                default:
                    return "OU=" + OtherOU + "," + StaffPath;
            }
        }

        public static string GetStudentpath(string group)
        {
            string path = null;

            int year = Convert.ToInt32(group[0].ToString());
            if (year < 1 || year > 7)
            {
                return null;
            }

            string className = group;

            path = "OU=" + className + ",";
            if (StudentYear.Length == 7)
            {
                path += "OU=" + StudentYear[year - 1] + ",";
            }

            if (StudentGrade.Length == 3)
            {
                switch (year)
                {
                    case 1:
                    case 2:
                        path += "OU=" + StudentGrade[0] + ","; break;
                    case 3:
                    case 4:
                        path += "OU=" + StudentGrade[1] + ","; break;
                    default:
                        path += "OU=" + StudentGrade[2] + ","; break;
                }
            }

            path += StudentPath;

            return path;
        }

        public static DirectoryEntry GetEntry(string path)
        {
            if (!path.StartsWith(Root))
            {
                path = Root + path;
            }

            if (DirectoryEntry.Exists(path))
            {
                return new DirectoryEntry(path);
            }
            else
            {
                return null;
            }
        }

        public static DirectoryEntry GetEntryByUID(string uid)
        {
            DirectorySearcher search = new DirectorySearcher();
            search.Filter = String.Format("(SAMAccountName={0})", uid);
            SearchResult result = search.FindOne();
            if (result == null) return null;
            return result.GetDirectoryEntry();
        }
    }
}
