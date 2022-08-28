﻿using Newtonsoft.Json.Linq;
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
                search.PropertiesToLoad.Add("wisaID");
                search.PropertiesToLoad.Add("classGroup");
                search.PropertiesToLoad.Add("gender");
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
                catch (System.Runtime.InteropServices.COMException e)
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
                catch (System.Runtime.InteropServices.COMException e)
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

        public static async Task<bool> Exists(string username)
        {
            return await Task<bool>.Run(() =>
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
            });
            
        }

        public static async Task<bool> HasAlias(string alias)
        {
            return await Task<bool>.Run(() =>
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
            });   
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

        public static Account GetStaffmemberByWisaName(string wisaID)
        {
            foreach (var account in Staff)
            {
                if (account.WisaID == wisaID) return account;
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
            await Task.Run(async () =>
            {
                try
                {
                    await account.Delete();
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
            await Task.Run(async () =>
            {
                try
                {
                    await account.Delete();
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
                    Connector.Log.AddError(Origin.Directory, "Unable to create homedir: " +  e.Message);
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


        public static async Task<Account> Create(string firstname, string lastname, string WisaID, AccountRole role, string classgroup = "", string uid = "")
        {
            return await Task.Run(async () =>
            {
                if (uid == "")
                {
                    uid = await Connector.CreateNewID(firstname, lastname);
                }
                

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

                if (role == AccountRole.Student)
                {
                    await setStudentDetails(childEntry, firstname, lastname, uid, WisaID, classgroup);
                    return await setStudentGroup(childEntry);
                }
                else
                {
                    await setStaffDetails(childEntry, firstname, lastname, uid); 
                    return await setStaffGroup(childEntry, role);
                }
            });

        }

        private static async Task setStudentDetails(DirectoryEntry entry, string firstName, string lastName, string uid, string wisaID, string classGroup)
        {
            string alias = await Connector.CreateNewAlias(firstName, lastName, true);

            try
            {
                entry.Properties["givenName"].Value = firstName;
                entry.Properties["sn"].Value = lastName;
                entry.Properties["displayName"].Value = firstName + " " + lastName;
                entry.Properties["mail"].Value = alias;
                entry.Properties["userPrincipalName"].Value = alias;

                // TODO: move mail alias to another property so we can get rid of the custom objectClass
                //entry.Properties["objectClass"].Add("smaSchoolPerson");
                //entry.Properties["smaMailAlias"].Value = alias;
                entry.Properties["wisaID"].Value = wisaID;
                entry.Properties["classGroup"].Value = classGroup;
                entry.CommitChanges();
                entry.RefreshCache();
            }
            catch (DirectoryServicesCOMException e)
            {
                Connector.Log.AddError(Origin.Directory, "unable to add details for " + firstName + " " + lastName + ": " + e.Message);
            }
        }

        private static async Task setStaffDetails(DirectoryEntry entry, string firstName, string lastName, string uid)
        {
            string alias = await Connector.CreateNewAlias(firstName, lastName);

            try
            {
                entry.Properties["givenName"].Value = firstName;
                entry.Properties["sn"].Value = lastName;
                entry.Properties["displayName"].Value = firstName + " " + lastName;
                entry.Properties["mail"].Value = alias;
                entry.Properties["userPrincipalName"].Value = alias;

                // TODO: move mail alias to another property so we can get rid of the custom objectClass
               // entry.Properties["objectClass"].Add("smaSchoolPerson");
               // entry.Properties["smaMailAlias"].Value = alias;
                entry.Properties["wisaID"].Value = uid; // wisa name is not known at this point, but we can change it later
                entry.CommitChanges();
                entry.RefreshCache();
            }
            catch (DirectoryServicesCOMException e)
            {
                Connector.Log.AddError(Origin.Directory, "unable to add account details for " + firstName + " " + lastName + ": " + e.Message);
            }
        }

        private static async Task<Account> setStudentGroup(DirectoryEntry entry)
        {
            var account = new Account(entry);
            //await account.SetHome();
            await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Leerlingen,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
            //await CreateHomeDir(account);
            Students.Add(account);
            return account;
        }

        private static async Task<Account> setStaffGroup(DirectoryEntry entry, AccountRole role)
        {
            var account = new Account(entry);
            //await account.SetHome();

            switch (role)
            {
                case AccountRole.Director:
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Directie,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    break;
                case AccountRole.Support:
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    break;
                case AccountRole.Maintenance:
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Onderhoud,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    break;
                case AccountRole.Teacher:
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Leraren,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    break;
                case AccountRole.IT:
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Secretariaat,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Leraren,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");
                    break;
            }
            await account.AddToGroup("CN=" + Connector.SchoolPrefix + "-Personnel,OU=ArcadiaGroups,DC=arcadiascholen,DC=be");

            //await CreateHomeDir(account);
            Staff.Add(account);
            return account;
        }

        public static void ApplyImportRules(List<IRule> rules)
        {
            for(int account = Students.Count -1; account >= 0; account--)
            {
                for(int i = 0; i < rules.Count; i++)
                {
                    if (rules[i].RuleAction == RuleAction.Modify) rules[i].Modify(Students[account]);
                    else if (rules[i].RuleAction == RuleAction.Discard && rules[i].ShouldApply(Students[account]))
                    {
                        Students.RemoveAt(account);
                        break;
                    }
                }
            }

            for(int account = Staff.Count - 1; account >= 0; account--)
            {
                for (int i = 0; i < rules.Count; i++)
                {
                    if (rules[i].RuleAction == RuleAction.Modify) rules[i].Modify(Staff[account]);
                    else if (rules[i].RuleAction == RuleAction.Discard && rules[i].ShouldApply(Staff[account]))
                    {
                        Staff.RemoveAt(account);
                        break;
                    }
                }
            }
        }
    }
}
