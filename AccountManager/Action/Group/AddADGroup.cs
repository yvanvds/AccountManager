using AccountApi.Directory;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    public class AddADGroup : GroupAction
    {
        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            if(linkedGroup != null)
            {
                var group = linkedGroup.Directory.Group;
                Connector.CreateOUIfneeded(State.App.Instance.AD.ClassesRoot.Value);
                ClassGroupManager.AddADGroup(State.App.Instance.Settings.SchoolPrefix.Value + "-" + linkedGroup.Directory.Group.Name);

                await State.App.Instance.AD.ReloadGroups().ConfigureAwait(false);
            }
        }

        public AddADGroup() : base(
            "AD Group voor klas toevoegen aan Active Directory",
            "Voeg deze groep toe.",
            true
        )
        { }

        public static void Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Directory.Linked)
            {
                if (State.App.Instance.AD.Groups.ADList.Find((a) => a.CN.Equals(State.App.Instance.Settings.SchoolPrefix.Value + "-" + group.Directory.Group.Name)) == null)
                     
                {
                    group.Actions.Add(new AddADGroup());
                    group.Directory.FlagWarning();
                }
            }
        }
    }
}
