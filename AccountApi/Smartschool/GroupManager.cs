using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Xml;

namespace AccountApi.Smartschool
{
    /// <summary>
    /// Manager for Groups in Smartschool. Groups are stored in an object tree. The root of 
    /// this tree is not a real object, but a container for all the groups in the main level of
    /// smartschool.
    /// </summary>
    public static class GroupManager
    {
        private static IGroup root = new Group(null);
        /// <summary>
        /// The root of the Group object tree. Will be null if no accounts are loaded.
        /// </summary>
        public static IGroup Root { get => root.Children?[0]; }

        /// <summary>
        /// Load all Groups from smartschool. This method will not reload if groups are already present. If a reload is 
        /// needed, use the reload method.
        /// </summary>
        /// <returns>awaitable</returns>
        public static async Task Load()
        {
            if (root != null) return;
            await Reload();
        }

        /// <summary>
        /// Counts the groups in the tree.
        /// </summary>
        /// <param name="onlyClassGroups">If true, only official groups (classes) will be included.</param>
        /// <returns></returns>
        public static int Count(bool onlyClassGroups)
        {
            if (root == null) return 0;
            if (onlyClassGroups) return root.CountClassGroupsOnly;
            return root.Count;
        }

        /// <summary>
        /// Reload the whole group object tree. The tree will be sorted when ready.
        /// </summary>
        /// <returns></returns>
        public static async Task Reload()
        {
            var result = await Task.Run(
              () => Connector.service.getAllGroupsAndClasses(Connector.password)
            );

            byte[] data = Convert.FromBase64String(result as string);
            string decoded = Encoding.UTF8.GetString(data);

            root = new Group(null);
            Group current = root as Group;
            using (XmlReader reader = XmlReader.Create(new StringReader(decoded)))
            {
                while (reader.Read())
                {
                    if (reader.IsStartElement())
                    {
                        switch (reader.Name)
                        {
                            case "group":
                                if (current.Children == null) current.Children = new List<IGroup>();
                                current.Children.Add(new Group(current));
                                current = current.Children.Last() as Group;
                                //Debug.WriteLine("new group");
                                break;
                            case "name":
                                if (reader.Read()) current.Name = reader.Value;
                                //Debug.WriteLine(current.Name);
                                break;
                            case "desc":
                                if (reader.Read()) current.Description = reader.Value;
                                //Debug.WriteLine(current.Description);
                                break;
                            case "type":
                                if (reader.Read()) switch (reader.Value)
                                    {
                                        case "G": current.Type = GroupType.Group; break;
                                        case "K": current.Type = GroupType.Class; break;
                                        default: current.Type = GroupType.Invalid; break;
                                    }
                                //Debug.WriteLine(current.Type);
                                break;
                            case "code":
                                if (reader.Read()) current.Code = reader.Value;
                                //Debug.WriteLine(current.Code);
                                break;
                            case "untis":
                                if (reader.Read()) current.Untis = reader.Value;
                                //Debug.WriteLine(current.Untis);
                                break;
                            case "visible":
                                if (reader.Read()) current.Visible = reader.Value.Equals("1") ? true : false;
                                //Debug.WriteLine(current.Visible);
                                break;
                            case "isOfficial":
                                if (reader.Read()) current.Official = reader.Value.Equals("1") ? true : false;
                                //Debug.WriteLine(current.Official);
                                break;
                            case "coAccountLabel":
                                if (reader.Read()) current.CoAccountLabel = reader.Value;
                                //Debug.WriteLine(current.CoAccountLabel);
                                break;
                            case "adminNumber":
                                if (reader.Read())
                                {
                                    int.TryParse(reader.Value, out int var);
                                    current.AdminNumber = var;
                                    //Debug.WriteLine(current.AdminNumber);
                                }
                                break;
                            case "instituteNumber":
                                if (reader.Read())
                                {
                                    current.InstituteNumber = reader.Value;
                                    //Debug.WriteLine(current.InstituteNumber);
                                }
                                break;
                            case "username":
                                if (reader.Read())
                                {
                                    if (current.Titulars == null) current.Titulars = new List<string>();
                                    current.Titulars.Add(reader.Value);
                                }
                                //Debug.WriteLine(current.Titulars.Last());
                                break;
                        }

                    }
                    else if (reader.NodeType == XmlNodeType.EndElement)
                    {
                        if (reader.Name == "group") // end of group
                        {
                            current = current.Parent as Group;
                            //Debug.WriteLine("switched to parent");
                        }
                    }
                }
            }

            if (root != null) Root.Sort();
        }

        public static void ApplyImportRules(List<IRule> rules)
        {
            if (Root != null)
            {

            }
        }

        /// <summary>
        /// Tries to determine what the logical parent should be for a class group. This
        /// works by evaluating the first character in the provided string, which should be a 
        /// number, indicating the year for this class. The method takes the current Smartschool
        /// configuration into account. Meaning that if only grades and no years are configured, the
        /// logical parent should be the grade group. If years are configured, the logical parent for 
        /// a class should be a year. If none are configured, the logical parent should be the path for
        /// all classes.
        /// </summary>
        /// <param name="classgroup">The name of the group, should start with a number.</param>
        /// <returns>The name of the logical parent.</returns>
        public static string GetLogicalParent(string classgroup)
        {
            string number = classgroup.Substring(0, 1);
            int year = 0;
            try
            {
                year = Convert.ToInt32(number);
            }
            catch (Exception e)
            {
                Error.AddError(e.Message);
                return "";
            }

            if (year < 1 || year > 7) return "";
            if (Connector.StudentYear.Count() == 7)
            {
                return Connector.StudentYear[year - 1];
            }
            else if (Connector.StudentGrade.Count() == 3)
            {
                switch (year)
                {
                    case 1:
                    case 2:
                        return Connector.StudentGrade[0];
                    case 3:
                    case 4:
                        return Connector.StudentGrade[1];
                    default:
                        return Connector.StudentGrade[2];
                }
            }
            return Connector.StudentPath;
        }

        /// <summary>
        /// Save the group to smartschool. This will save the group's name, description, group code, parent group code,
        /// untis ID, (institute number and administrative number for official groups). Please note that smartschool does not accept groups without
        /// a description.
        /// </summary>
        /// <param name="group">The group to save</param>
        /// <returns>True if succeeded. Else false.</returns>
        public static async Task<bool> Save(IGroup group)
        {
            int result = 0;

            if (group.Type == GroupType.Class)
            {
                var r = await Task.Run(() => Connector.service.saveClass(
                  Connector.password,
                  group.Name,
                  group.Description, // TODO: add warning (empty description is not accepted by smartschool)
                  group.Code,
                  group.Parent.Code,
                  group.Untis,
                  group.InstituteNumber,
                  group.AdminNumber.ToString(),
                  ""
                ));
                result = Convert.ToInt32(r);
            }
            else if (group.Type == GroupType.Group)
            {
                var r = await Task.Run(() => Connector.service.saveGroup(
                  Connector.password,
                  group.Name,
                  group.Description,
                  group.Code,
                  group.Parent.Code,
                  group.Untis
                ));
                result = Convert.ToInt32(r);
            }

            if (result != 0)
            {
                Error.AddError(result);
                return false;
            }
            return true;
        }

        /// <summary>
        /// Deletes the group from smartschool.
        /// </summary>
        /// <param name="group">The group to delete</param>
        /// <returns>True on success. Else false.</returns>
        public static async Task<bool> Delete(IGroup group)
        {
            var result = await Task.Run(() => Connector.service.delClass(
              Connector.password,
              group.Code
            ));

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }
            return true;
        }

        /// <summary>
        /// Moves a student to another official class. The group must be an official group with GroupType.Class.
        /// The date provided is very important, because this is an official class change. Changes to the student's 
        /// evaluation will look at the date of this change.
        /// </summary>
        /// <param name="account">The account to move.</param>
        /// <param name="group">The new class.</param>
        /// <param name="date">The official date of this change.</param>
        /// <returns>True on success. Else false.</returns>
        public static async Task<bool> MoveUserToClass(IAccount account, IGroup group, DateTime date)
        {
            if (group.Type != GroupType.Class || !group.Official)
            {
                Connector.Log.AddError(Origin.Smartschool, "Groups API: You can only move users to official classes");
                return false;
            }
            var result = await Task.Run(() => Connector.service.saveUserToClass(
              Connector.password,
              account.UID,
              group.Name,
              Utils.DateToString(date)
            ));

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            } else
            {
                account.Group = group.Name;
            }
            return true;
        }

        /// <summary>
        /// Adds a user to a group. The target group cannot be an official group. To move a student to a new official group,
        /// the MoveUserToClass method should be used.
        /// </summary>
        /// <param name="account">The account to add.</param>
        /// <param name="group">The target group.</param>
        /// <returns>True on success. Else false.</returns>
        public static async Task<bool> AddUserToGroup(IAccount account, IGroup group)
        {
            if (group.Official)
            {
                Connector.Log.AddError(Origin.Smartschool, "Groups API: Users cannot be added to official classes. Use the MoveUserToClass method instead.");
                return false;
            }
            var result = await Task.Run(() => Connector.service.saveUserToClassesAndGroups(
              Connector.password,
              account.UID,
              group.Name,
              1
            ));

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }
            return true;
        }

        /// <summary>
        /// Removes a user from a group. The group should not be an official group.
        /// </summary>
        /// <param name="account">The account to remove</param>
        /// <param name="group">The group to remove the account from.</param>
        /// <returns>True on success. Else false.</returns>
        public static async Task<bool> RemoveUserFromGroup(IAccount account, IGroup group)
        {
            if (group.Official)
            {
                Connector.Log.AddError(Origin.Smartschool, "Groups API: Users cannot be removed from official classes.");
                return false;
            }

            var result = await Task.Run(() => Connector.service.removeUserFromGroup(
              Connector.password,
              account.UID,
              group.Name,
              Utils.DateToString(DateTime.Now)
            ));

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }
            return true;
        }

        public static JObject ToJson(bool includeAccounts)
        {
            JObject result = null;
            if (Root != null)
            {
                result = Root.ToJson(includeAccounts);
            }
            return result;
        }

        public static void FromJson(JObject obj)
        {
            root = new Group(null)
            {
                Children = new List<IGroup>()
            };
            root.Children.Add(new Group(root, obj));
        }
    }
}
