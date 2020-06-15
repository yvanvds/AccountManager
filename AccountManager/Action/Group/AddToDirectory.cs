using AccountApi.Directory;
using System;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    public class AddToDirectory : GroupAction
    {
        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            if (linkedGroup != null)
            {
                var wisa = linkedGroup.Wisa.Group;
                var path = Connector.GetStudentpath(wisa.Name);

                Connector.CreateOUIfneeded(path);
                await State.App.Instance.AD.ReloadGroups().ConfigureAwait(false);
            }
            
            // return Task.FromResult(0);
        }

        public AddToDirectory() : base(
            "Klas toevoegen aan Active Directory",
            "Voeg deze klas toe aan Active Directory.",
            true)
        {

        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Wisa.Linked && !group.Directory.Linked)
            {
                group.Actions.Add(new AddToDirectory());
                return true;
            }
            return false;
        }
    }
}
