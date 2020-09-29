using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.DirectoryServices;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public class Account
    {
        public Account(DirectoryEntry entry)
        {
            uid = entry.Properties.Contains("sAMAccountName") ? entry.Properties["sAMAccountName"].Value.ToString() : "";
            firstName = entry.Properties.Contains("givenName") ? entry.Properties["givenName"].Value.ToString() : "";
            lastName = entry.Properties.Contains("sn") ? entry.Properties["sn"].Value.ToString() : "";
            fullName = entry.Properties.Contains("displayname") ? entry.Properties["displayname"].Value.ToString() : "";
            mail = entry.Properties.Contains("mail") ? entry.Properties["mail"].Value.ToString() : "";
            principalName = entry.Properties.Contains("userPrincipalName") ? entry.Properties["userPrincipalName"].Value.ToString() : "";
            wisaID = entry.Properties.Contains("wisaID") ? entry.Properties["wisaID"].Value.ToString() : "";
            classGroup = entry.Properties.Contains("classGroup") ? entry.Properties["classGroup"].Value.ToString() : "";
            gender = entry.Properties.Contains("gender") ? entry.Properties["gender"].Value.ToString() : "not set";
            copyCode = entry.Properties.Contains("employeeID") ? Convert.ToInt32(entry.Properties["employeeID"].Value) : 0;
            state = entry.Properties.Contains("userAccountControl") ? (int)entry.Properties["userAccountControl"].Value : 0;
            role = Connector.GetRoleFromPath(entry.Path);
            cn = entry.Properties.Contains("cn") ? entry.Properties["cn"].Value.ToString() : "";

            groups = new List<string>();
            if (entry.Properties.Contains("memberOf"))
            {
                foreach (string group in entry.Properties["memberOf"])
                {
                    groups.Add(group);
                }
            }

            homeDrive = entry.Properties.Contains("HomeDrive") ? entry.Properties["HomeDrive"].Value.ToString() : "";
            homeDirectory = entry.Properties.Contains("HomeDirectory") ? entry.Properties["HomeDirectory"].Value.ToString() : "";
        }

        public Account(JObject obj)
        {
            uid = obj.ContainsKey("uid") ? obj["uid"].ToString() : "";
            firstName = obj.ContainsKey("firstName") ? obj["firstName"].ToString() : "";
            lastName = obj.ContainsKey("lastName") ? obj["lastName"].ToString() : "";
            fullName = obj.ContainsKey("fullName") ? obj["fullName"].ToString() : "";
            mail = obj.ContainsKey("mail") ? obj["mail"].ToString() : "";
            principalName = obj.ContainsKey("userPrincipalName") ? obj["userPrincipalName"].ToString() : "";
            wisaID = obj.ContainsKey("wisaID") ? obj["wisaID"].ToString() : "";
            classGroup = obj.ContainsKey("classGroup") ? obj["classGroup"].ToString() : "";
            gender = obj.ContainsKey("gender") ? obj["gender"].ToString() : "not set";
            state = obj.ContainsKey("state") ? Convert.ToInt32(obj["state"]) : 0;
            copyCode = obj.ContainsKey("copyCode") ? Convert.ToInt32(obj["copyCode"]) : 0;

            homeDrive = obj.ContainsKey("homeDrive") ? obj["homeDrive"].ToString() : "";
            homeDirectory = obj.ContainsKey("homeDirectory") ? obj["homeDirectory"].ToString() : "";

            string sRole = obj.ContainsKey("role") ? obj["role"].ToString() : "";
            switch(sRole)
            {
                case "Student": role = AccountRole.Student; break;
                case "Teacher": role = AccountRole.Teacher; break;
                case "Director": role = AccountRole.Director; break;
                case "Support": role = AccountRole.Support; break;
                case "Maintenance": role = AccountRole.Maintenance; break;
                case "IT": role = AccountRole.IT; break;
                default: role = AccountRole.Other; break;
            } 
            cn = obj.ContainsKey("cn") ? obj["cn"].ToString() : "";

            groups = new List<string>();
            if (obj.ContainsKey("groups"))
            {
                JArray jGroups = obj["groups"] as JArray;
                
                foreach(var group in jGroups)
                {
                    groups.Add(group.ToString());
                }
            }
        }

        public JObject ToJson()
        {
            var jGroups = new JArray();
            foreach(var group in groups)
            {
                jGroups.Add(group);
            }

            var result = new JObject
            {
                ["uid"] = uid,
                ["firstName"] = firstName,
                ["lastName"] = lastName,
                ["fullName"] = fullName,
                ["mail"] = mail,
                ["userPrincipalName"] = principalName,
                ["wisaID"] = wisaID,
                ["classGroup"] = classGroup,
                ["state"] = state,
                ["copyCode"] = copyCode,
                ["gender"] = gender,
                ["role"] = role.ToString(),
                ["cn"] = CN,
                ["groups"] = jGroups,
                ["homeDrive"] = homeDrive,
                ["homeDirectory"] = homeDirectory, 
            };
            return result;
        }

        private string uid;
        public string UID { get => uid; }

        private string firstName;
        public string FirstName
        {
            get => firstName;
            set
            {
                var entry = GetEntry(uid);
                firstName = value;
                fullName = firstName + " " + LastName;
                entry.Properties["givenName"].Value = firstName;
                entry.Properties["displayname"].Value = fullName;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string lastName;
        public string LastName
        {
            get => lastName;
            set
            {
                var entry = GetEntry(uid);
                lastName = value;
                fullName = firstName + " " + LastName;
                entry.Properties["sn"].Value = lastName;
                entry.Properties["displayname"].Value = fullName;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string fullName;
        public string FullName { get => fullName; }

        private string gender;
        public string Gender
        {
            get => gender;
            set
            {
                var entry = GetEntry(uid);
                gender = value;
                entry.Properties["gender"].Value = gender;
                entry.CommitChanges();
                entry.Close();
            }
        }

        private string cn;
        public string CN {
            get => cn;
            set
            {
                cn = value;
                try
                {
                    var entry = GetEntry(uid);
                    entry.Rename("CN=" + cn);
                    entry.CommitChanges();
                    entry.Close();
                }
                catch (Exception) { }
                
            }
        }

        private string mail;
        public string Mail
        {
            get => mail;
            set
            {
                mail = value;
                try
                {
                    var entry = GetEntry(uid);
                    entry.Properties["mail"].Value = mail;
                    entry.CommitChanges();
                    entry.Close();
                }
                catch (Exception) { }
            }
        }

        private string principalName;
        public string PrincipalName
        {
            get => principalName;
            set
            {
                principalName = value;
                try
                {
                    var entry = GetEntry(uid);
                    entry.Properties["userPrincipalName"].Value = principalName;
                    entry.CommitChanges();
                    entry.Close();
                }
                catch (Exception) { }
            }
        }

        private List<string> groups = new List<string>();
        public List<string> Groups
        {
            get => groups;
        }
        public async Task AddToGroup(string groupPath)
        {
            await Task.Run(() =>
            {
                try
                {
                    DirectoryEntry groupEntry = Connector.GetEntry(groupPath);
                    if (groupEntry != null)
                    {
                        var user = GetEntry(uid);
                        string path = user.Properties["distinguishedName"].Value.ToString();
                        groupEntry.Properties["member"].Add(path);
                        groupEntry.CommitChanges();
                        Connector.Log.AddMessage(Origin.Directory, fullName + " is now part of group: " + groupEntry.Path);
                        groupEntry.Close();
                        user.Close();
                        groups.Add(groupPath);
                    }
                    else
                    {
                        Connector.Log.AddError(Origin.Directory, "Cannot add a member to an unknown group.");
                    }
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                }
            });
            
        }

        public async Task RemoveFromGroup(string groupPath)
        {
            await Task.Run(() =>
            {
                try
                {
                    DirectoryEntry groupEntry = Connector.GetEntry(groupPath);
                    if (groupEntry != null)
                    {
                        var user = GetEntry(uid);
                        string path = user.Properties["distinguishedName"].Value.ToString();
                        groupEntry.Properties["member"].Remove(path);
                        groupEntry.CommitChanges();
                        groupEntry.Close();
                        user.Close();
                        groups.Remove(groupPath);
                    }
                    else
                    {
                        Connector.Log.AddError(Origin.Directory, "Cannot remove a member from an unknown group.");
                    }
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                }
            });
           
        }

        private string wisaID;
        public string WisaID { get => wisaID; }

        public async Task SetWisaID(string id)

        {

            await Task.Run(() =>

            {

                var entry = GetEntry(uid);

                wisaID = id;

                entry.Properties["wisaID"].Value = wisaID;

                entry.CommitChanges();

                entry.Close();

            });

        }

        private string classGroup;
        public string ClassGroup { get => classGroup; }

        private string homeDrive;
        public string HomeDrive { get => homeDrive; }

        private string homeDirectory;
        public string HomeDirectory { get => homeDirectory; }

        public bool HasCorrectHome()
        {
            switch (Role)
            {
                case AccountRole.Student:
                    if (homeDrive != "L:") return false;
                    if (homeDirectory != "\\\\fsstudents\\homes\\" + uid) return false;
                    break;
                case AccountRole.IT:
                case AccountRole.Support:
                case AccountRole.Director:
                    if (homeDrive != "H:") return false;
                    if (homeDirectory != "\\\\Datacenter1\\SupportHomes\\" + uid) return false;
                    break;
                case AccountRole.Teacher:
                    if (homeDrive != "H:") return false;
                    if (homeDirectory != "\\\\fsteachers\\homes\\" + uid) return false;
                    break;
            }
            return true;
        }

        public async Task SetHome()
        {
            await Task.Run(() =>
            {
                try
                {
                    var entry = GetEntry(uid);
                    switch (Role)
                    {
                        case AccountRole.Student:
                            homeDrive = "L:";
                            homeDirectory = "\\\\fsstudents\\homes\\" + uid;
                            break;
                        case AccountRole.IT:
                        case AccountRole.Support:
                        case AccountRole.Director:
                            homeDrive = "H:";
                            homeDirectory = "\\\\Datacenter1\\SupportHomes\\" + uid;
                            break;
                        case AccountRole.Teacher:
                            homeDrive = "H:";
                            homeDirectory = "\\\\fsteachers\\homes\\" + uid;
                            break;
                    }
                    entry.Properties["HomeDrive"].Value = homeDrive;
                    entry.Properties["HomeDirectory"].Value = homeDirectory;
                    entry.CommitChanges();
                    entry.Close();

                } catch(Exception e)
                {
                    Connector.Log.AddError(Origin.Directory, e.Message);
                }
            });
        }


        private int copyCode;
        public int CopyCode {
            get => copyCode;
            set
            {
                var entry = GetEntry(uid);
                copyCode = value;
                entry.Properties["employeeID"].Value = copyCode.ToString();
                entry.CommitChanges();
                entry.Close();
            }
        }



        int state;
        internal int State
        {
            get => state;

            set
            {
                var entry = GetEntry(uid);
                state = value;
                entry.Properties["userAccountControl"].Value = value;
                entry.CommitChanges();
                entry.Close();
            }
        }

        AccountRole role;
        public AccountRole Role
        {
            get => role;
            set
            {
                if(value != AccountRole.Student)
                {
                    // never change a student to something else
                    var entry = GetEntry(UID);
                    role = value;
                    string path = Connector.GetPath(role);
                    var parent = Connector.GetEntry(path);
                    entry.MoveTo(parent);
                    entry.CommitChanges();
                    entry.Close();
                }
            }
        }

        public void Disable()
        {
            const int DISABLE_ACCOUNT = 0x0002;
            State |= DISABLE_ACCOUNT;
        }

        public void Enable()
        {
            const int DISABLE_ACCOUNT = 0x0002;
            State &= ~DISABLE_ACCOUNT;
        }

        public bool IsEnabled()
        {
            return (State & 0x0002) == 0;
        }

        public async Task Delete()
        {
            var entry = GetEntry(uid);
            if(entry != null)
            {
                string home = string.Empty ;
                if (entry.Properties["HomeDirectory"] != null)
                {
                    if (entry.Properties["HomeDirectory"].Value != null)
                        home = entry.Properties["HomeDirectory"].Value.ToString();
                }
                if(home != string.Empty)
                {
                    await Task.Run(() =>
                    {
                        try
                        {
                            ProcessStartInfo Info = new ProcessStartInfo();
                            Info.Arguments = "/C rd /s /q \"" + home + "\"";
                            Info.WindowStyle = ProcessWindowStyle.Hidden;
                            Info.CreateNoWindow = true;
                            Info.FileName = "cmd.exe";
                            Process.Start(Info);
                            //var dir = new DirectoryInfo(home);
                            //dir.Delete(true);
                        }
                        catch (Exception e)
                        {
                            Connector.Log.AddError(Origin.Directory, e.Message);
                        }
                    });  
                }
                var parent = entry.Parent;
                if (parent != null)
                {
                    parent.Children.Remove(entry);
                    parent.CommitChanges();
                    parent.Close();
                }
                entry.Close();
            }
            
        }

        public void SetPassword(string password)
        {
            var entry = GetEntry(uid);
            try
            {
                //entry.Password = password;
                entry.Invoke("SetPassword", new object[] { password });
                entry.CommitChanges();
            }
            catch(Exception e)
            {
                Connector.Log.AddError(Origin.Directory, e.Message);
            }
        }

        public void MoveToClassGroup(DirectoryEntry newParent, string ClassGroup)
        {
            var entry = GetEntry(UID);
            classGroup = ClassGroup;
            entry.Properties["classGroup"].Value = ClassGroup;
            entry.CommitChanges();
            entry.MoveTo(newParent);
            entry.CommitChanges();
            entry.Close();
        }

        private static DirectoryEntry GetEntry(string uid)
        {
            return Connector.GetEntryByUID(uid);
        }

        public string DesiredCN()
        {
            return fullName + " (" + uid + ")";
        }
    }
}
