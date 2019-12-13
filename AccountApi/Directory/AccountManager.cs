using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public static class AccountManager
    {
        public static List<Account> Students = new List<Account>();
        public static List<Account> Staff = new List<Account>();


        public static async Task<bool> LoadStudents()
        {
            Students.Clear();
            var result = await Task.Run(() =>
            {
                DirectorySearcher search = Connector.GetSearcher(Connector.StudentPath);
                search.Filter = "(ObjectClass=*)";
                search.PageSize = 10000;
                search.PropertiesToLoad.Clear();
                search.PropertiesToLoad.Add("sAMAccountName");
                search.PropertiesToLoad.Add("givenName");
                search.PropertiesToLoad.Add("sn");
                search.PropertiesToLoad.Add("displayname");
                search.PropertiesToLoad.Add("smamailalias");
                search.PropertiesToLoad.Add("smaWisaID");
                search.PropertiesToLoad.Add("smawisaname");
                search.PropertiesToLoad.Add("smaClass");
                search.PropertiesToLoad.Add("samGender");
                search.PropertiesToLoad.Add("userAccountControl");
                search.PropertiesToLoad.Add("employeeID");
                search.PropertiesToLoad.Add("memberOf");
                SearchResultCollection results;

                try
                {
                    results = search.FindAll();
                }
                catch (DirectoryServicesCOMException e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                    return false;
                }

                int count = 0;
                foreach (SearchResult r in results)
                {
                    DirectoryEntry entry = r.GetDirectoryEntry();

                    // don't parse OU's
                    if (entry.Name.StartsWith("OU")) continue;
                    Students.Add(new Account(entry));
                    count++;
                    if (count % 50 == 0)
                    {
                        Connector.Log.AddMessage(Origin.Directory, "Added " + count.ToString() + " Student Accounts");
                    }
                }
                results.Dispose();

                Connector.Log.AddMessage(Origin.Directory, "Added " + count.ToString() + " Student Accounts");
                return true;
            });

            return result;
        }

        public static async Task<bool> LoadStaff()
        {
            Staff.Clear();
            var result = await Task.Run(() =>
            {
                DirectorySearcher search = Connector.GetSearcher(Connector.StaffPath);
                search.Filter = "(ObjectClass=*)";
                search.SizeLimit = 20000;
                SearchResultCollection results;

                try
                {
                    results = search.FindAll();
                }
                catch (DirectoryServicesCOMException e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                    return false;
                }

                int count = 0;
                foreach (SearchResult r in results)
                {
                    DirectoryEntry entry = r.GetDirectoryEntry();

                    // don't parse OU's
                    if (entry.Name.StartsWith("OU")) continue;
                    Staff.Add(new Account(entry));
                    count++;
                    if(count % 50 == 0)
                    {
                        Connector.Log.AddMessage(Origin.Directory, "Added " + count.ToString() + " Staff Accounts");
                    }
                }

                Connector.Log.AddMessage(Origin.Directory, "Added " + count.ToString() + " Staff Accounts");
                return true;
            });

            return result;
        }

        public static JObject ToJson()
        {
            JObject result = new JObject();

            var students = new JArray();
            foreach (var account in Students)
            {
                students.Add(account.ToJson());
            }
            result["Students"] = students;

            var staff = new JArray();
            foreach (var account in Staff)
            {
                staff.Add(account.ToJson());
            }
            result["Staff"] = staff;

            return result;
        }

        public static void FromJson(JObject obj)
        {
            Students.Clear();
            Staff.Clear();

            var students = obj["Students"]?.ToArray();
            if (students != null) foreach (var student in students)
            {
                Students.Add(new Account(student as JObject));
            }

            var staff = obj["Staff"]?.ToArray();
            if (staff != null) foreach (var account in staff)
            {
                Staff.Add(new Account(account as JObject));
            }
        }

        public static bool Exists(string username)
        {
            DirectorySearcher search = Connector.GetSearcher(Connector.AccountPath);
            search.Filter = $"(samaccountname={username})";
            SearchResult result;

            try
            {
                result = search.FindOne();

            }
            catch (DirectoryServicesCOMException)
            {
                return false;
            }
            if (result == null) return false;

            return true;
        }

        public static bool HasAlias(string alias)
        {
            DirectorySearcher search = Connector.GetSearcher(Connector.AccountPath);
            search.Filter = $"(smamailalias={alias})";
            SearchResult result;

            try
            {
                result = search.FindOne();

            }
            catch (DirectoryServicesCOMException)
            {
                return false;
            }
            if (result == null) return false;

            return true;
        }

        public static bool ContainsStudents(ClassGroup classGroup)
        {
            foreach (var student in Students)
            {
                if (student.ClassGroup == classGroup.Name) return true;
            }
            return false;
        }

        public static Account GetStudentByWisaID(string wisaID)
        {
            foreach (var student in Students)
            {
                if (student.WisaID == wisaID) return student;
            }
            return null;
        }

        public static Account GetStaffmemberByWisaID(string wisaID)
        {
            foreach (var account in Staff)
            {
                if (account.WisaName == wisaID) return account;
            }
            return null;
        }

        public static Account GetStaffmemberByName(string firstName, string lastName)
        {
            foreach (var account in Staff)
            {
                if (account.FirstName.Equals(firstName, StringComparison.CurrentCultureIgnoreCase) && account.LastName.Equals(lastName, StringComparison.CurrentCultureIgnoreCase))
                {
                    return account;
                }
            }
            return null;
        }

        public static async Task DeleteStaff(Account account)
        {
            await Task.Run(() =>
            {
                try
                {
                    account.Delete();
                    Staff.Remove(account);
                    Connector.Log.AddMessage(Origin.Directory, account.FullName + ": account deleted");
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                }
            });
        }

        public static async Task DeleteStudent(Account account)
        {
            await Task.Run(() =>
            {
                try
                {
                    account.Delete();
                    Students.Remove(account);
                    Connector.Log.AddMessage(Origin.Directory, account.FullName + ": account deleted");
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                }
            }); 
        }

        public static async Task<bool> MoveStudentToClass(Account account, string ClassGroup)
        {
            return await Task.Run(() =>
            {
                string path = Connector.GetPath(AccountRole.Student, ClassGroup);
                if (path == null)
                {
                    Connector.Log.AddError(Origin.Directory, "unable to move account to " + ClassGroup);
                    return false;
                }
                Connector.CreateOUIfneeded(path);

                DirectoryEntry newParent = Connector.GetEntry(path);
                if (newParent == null)
                {
                    Connector.Log.AddError(Origin.Directory, "cannot get path: " + path);
                    return false;
                }

                account.MoveToClassGroup(newParent, ClassGroup);
                return true;
            });
            
        }

        public static async Task<bool> CreateHomeDir(Account account)
        {
            return await Task.Run(() =>
            {
                try
                {
                    if (!System.IO.Directory.Exists(account.HomeDirectory))
                    {
                        System.IO.Directory.CreateDirectory(account.HomeDirectory);
                    }

                    FileSystemRights rights = FileSystemRights.FullControl;
                    InheritanceFlags flags = new InheritanceFlags();
                    flags = InheritanceFlags.None;

                    FileSystemAccessRule accessRule = new FileSystemAccessRule(account.UID, rights, flags, PropagationFlags.NoPropagateInherit, AccessControlType.Allow);
                    DirectoryInfo dInfo = new DirectoryInfo(account.HomeDirectory);
                    DirectorySecurity dSec = dInfo.GetAccessControl();

                    bool modified;
                    dSec.ModifyAccessRule(AccessControlModification.Set, accessRule, out modified);

                    InheritanceFlags iFlags = new InheritanceFlags();
                    iFlags = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;

                    FileSystemAccessRule accessRule2 = new FileSystemAccessRule(account.UID, rights, iFlags, PropagationFlags.InheritOnly, AccessControlType.Allow);
                    dSec.ModifyAccessRule(AccessControlModification.Add, accessRule2, out modified);

                    dInfo.SetAccessControl(dSec);
                    return true;
                } catch(Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                    if (System.IO.Directory.Exists(account.HomeDirectory))
                    {
                        try
                        {
                            System.IO.Directory.Delete(account.HomeDirectory);
                        } catch(Exception ex)
                        {
                            Connector.Log.AddError(Origin.Directory, ex.Message);
                        }
                        
                    }
                    return false;
                }
            });
        }

        public static async Task<Account> Create(string firstname, string lastname, string WisaID, AccountRole role, string classgroup = "")
        {
            return await Task.Run(async () =>
            {
                string uid = Connector.CreateNewID(firstname, lastname);
                string alias = Connector.CreateNewAlias(firstname, lastname);

                string path = Connector.GetPath(role, classgroup);
                if (path == null)
                {
                    Connector.Log.AddError(Origin.Directory, "unable to add account for " + firstname + " " + lastname);
                    return null;
                }
                Connector.CreateOUIfneeded(path);

                DirectoryEntry ouEntry = Connector.GetEntry(path);
                if (ouEntry == null)
                {
                    Connector.Log.AddError(Origin.Directory, "Account creation went wrong. (cannot get path: " + path + ")");
                    return null;
                }

                DirectoryEntry childEntry = null;
                int NORMAL_ACCOUNT = 0x200;
                int PWD_NOTREQUIRED = 0x20;
                try
                {
                    var cn = firstname + " " + lastname + " (" + uid + ")";
                    childEntry = ouEntry.Children.Add($"CN={cn}", "user");
                    childEntry.Properties["sAMAccountName"].Value = uid;
                    childEntry.Properties["userAccountControl"].Value = NORMAL_ACCOUNT | PWD_NOTREQUIRED;
                    childEntry.CommitChanges();
                    ouEntry.CommitChanges();

                    childEntry.RefreshCache();
                }
                catch (DirectoryServicesCOMException e)
                {
                    Connector.Log.AddError(Origin.Directory, "unable to add account for " + firstname + " " + lastname + ": " + e.Message);
                    return null;
                }

                try
                {
                    childEntry.Properties["givenName"].Value = firstname;
                    childEntry.Properties["sn"].Value = lastname;
                    childEntry.Properties["displayname"].Value = firstname + " " + lastname;
                    //childEntry.Properties["mail"].Value = uid + "@sanctamaria-aarschot.be";
                    childEntry.Properties["userprincipalname"].Value = uid + "@" + Connector.AzureDomain;

                    // TODO: move mail alias to another property so we can get rid of the custom objectClass
                    childEntry.Properties["objectClass"].Add("smaSchoolPerson");
                    childEntry.Properties["smamailalias"].Value = alias;
                    childEntry.Properties["smaWisaID"].Value = WisaID;
                    childEntry.Properties["smawisaname"].Value = WisaID;
                    childEntry.Properties["smaClass"].Value = classgroup;
                    childEntry.CommitChanges();
                    childEntry.RefreshCache();
                }
                catch (DirectoryServicesCOMException e)
                {
                    Connector.Log.AddError(Origin.Directory, "unable to add account for " + firstname + " " + lastname + ": " + e.Message);
                    return null;
                }

                if (role == AccountRole.Student)
                {
                    var account = new Account(childEntry);
                    await account.SetHome();
                    await account.AddToGroup("CN=Students,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
                    await CreateHomeDir(account);
                    Students.Add(account);
                    return account;
                }
                else
                {
                    var account = new Account(childEntry);
                    await account.SetHome();

                    switch(role) {
                        case AccountRole.Director:
                            await account.AddToGroup("CN=Directors,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
                            await account.AddToGroup("CN=Support,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
                            break;
                        case AccountRole.Support:
                            await account.AddToGroup("CN=Support,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
                            break;
                        case AccountRole.Teacher:
                            await account.AddToGroup("CN=Teachers,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
                            break;
                    }

                    await CreateHomeDir(account);
                    Staff.Add(account);
                    return account;
                }
            });

        }
    }
}
